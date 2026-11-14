package com.lazysend.lazysend.host

import com.lazysend.lazysend.link.ItemRequest
import com.lazysend.lazysend.link.ItemState
import com.lazysend.lazysend.transfer.ReceivedFiles
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import kotlinx.serialization.Serializable

/** A file being received, or finished within the last day, kept in a small JSON file so a restart can go on. */
@Serializable
class IncomingFile(
    val id: String,
    val deviceId: String,
    val deviceName: String,
    val name: String,
    val size: Long,
    val mime: String? = null,
    val modified: Long? = null,
    val sourceId: String? = null,
    val sha256: String? = null,
    val folder: String,
    var uri: String = "",
    val started: Long,
    var updated: Long,
    var done: Boolean = false,
    var finished: Long? = null,
)

/**
 * Files from guests: begun with the item's metadata, filled in chunks into a half-written file in the folder they will end
 * up in, and put in place when the last byte is in and the SHA-256, when given, matches. The offset a guest resumes from is
 * the length of the half-written file, so what was written before a dropped connection or a restart counts. One chunk is
 * written at a time per file: a newer request takes over from one that is still open (the guest has already given up on
 * that connection). Blocking; call it from a worker thread.
 */
class Inbox(
    private val directory: File,
    private val files: ReceivedFiles,
    private val index: GalleryIndex,
    private val freeSpace: () -> Long,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val gate = Any()
    private val records = HashMap<String, IncomingFile>()

    // The unfinished file of each (guest, source id), so a gallery sync of tens of thousands of photos does not scan every record.
    private val bySource = HashMap<Pair<String, String>, IncomingFile>()
    private val writers = ConcurrentHashMap<String, Writer>()
    private var lastPrune = 0L

    var onProgress: (IncomingFile, Long) -> Unit = { _, _ -> }
    var onBegun: (IncomingFile) -> Unit = {}
    var onFinished: (IncomingFile) -> Unit = {}

    private class Writer {
        val gate = Semaphore(1)

        @Volatile
        var stop: (() -> Unit)? = null
        var digest: MessageDigest? = null
        var hashed = 0L
    }

    /** Starts a file, or finds the one already started for the same source id. A source id received before answers done. */
    fun begin(guest: Guest, request: ItemRequest): ItemState {
        val size = request.size?.takeIf { it >= 0 } ?: throw HostError.badRequest
        val sourceId = request.sourceId
        if (sourceId != null && !isValidSourceId(sourceId)) throw HostError.badRequest
        val sha256 = request.sha256?.let {
            if (it.length != 64 || !it.all { c -> c in '0'..'9' || c in 'a'..'f' || c in 'A'..'F' }) throw HostError.badRequest
            it.lowercase()
        }
        val duplicate = ItemState("", size, true, true)
        if (sourceId != null && index.contains(guest.id, sourceId)) return duplicate

        val now = clock()
        pruneIfDue(now)
        val modified = parseModified(request.modified)
        var folder = cleanFileName(guest.name, "Phone")
        if (sourceId != null) folder += "/Gallery/" + MONTH.format(Instant.ofEpochMilli(modified ?: now))
        if (freeSpace() - size < MIN_FREE_BYTES) throw HostError.diskFull
        val file = IncomingFile(
            newId(), guest.id, guest.name, cleanFileName(request.name), size, request.mime, modified, sourceId, sha256, folder,
            started = now, updated = now,
        )
        // Looked up and added in one step, so two requests for the same asset cannot start two transfers. A finished
        // transfer is in the index before it leaves bySource, so one of the two always shows it.
        var existing: IncomingFile? = null
        synchronized(gate) {
            if (sourceId != null) {
                val known = bySource[guest.id to sourceId]
                when {
                    known != null && known.size == size -> existing = known
                    known == null && index.contains(guest.id, sourceId) -> return duplicate
                }
            }
            if (existing == null) {
                try {
                    file.uri = files.create(file.name, file.mime, folder).uri
                } catch (e: Exception) {
                    throw failed(e)
                }
                records[file.id] = file
                if (sourceId != null) bySource[guest.id to sourceId] = file
            }
        }
        existing?.let {
            finishIfFull(it)
            return stateOf(it)
        }
        try {
            save(file)
            onBegun(file)
            if (size == 0L) complete(file, null)
        } catch (e: Exception) {
            discard(file)
            throw e as? HostError ?: failed(e)
        }
        return stateOf(file)
    }

    /** Where a file of [deviceId] stands; null when there is no such file. */
    fun state(deviceId: String, id: String): ItemState? {
        val file = synchronized(gate) { records[id] } ?: return null
        if (file.deviceId != deviceId) return null
        finishIfFull(file)
        return synchronized(gate) { records[id] }?.let { stateOf(it) }
    }

    /**
     * Writes [length] bytes of [body] at [offset]. [abort] ends this connection; a newer request for the same file calls it.
     * Throws [HostError] and, when the connection breaks, [IOException] after keeping what arrived.
     */
    fun write(deviceId: String, id: String, offset: Long, length: Long, body: RequestBody, abort: () -> Unit): ItemState {
        val file = synchronized(gate) { records[id] }
        if (file == null || file.deviceId != deviceId) throw HostError.notFound
        if (file.done) {
            // The last chunk got through but its answer did not.
            body.discard(length)
            return stateOf(file)
        }
        if (length < 0 || (length == 0L && offset != file.size) || offset < 0 || offset > file.size || length > file.size - offset) throw HostError.badRequest
        if (length > MAX_CHUNK_BYTES) throw HostError.tooLarge
        if (freeSpace() - length < MIN_FREE_BYTES) throw HostError.diskFull

        val writer = writers.computeIfAbsent(id) { Writer() }
        if (!writer.gate.tryAcquire()) {
            if (!takeOver(writer)) throw HostError.busy
        }
        writer.stop = abort
        try {
            // The record may have been discarded while this request waited for the gate.
            synchronized(gate) { if (!records.containsKey(id)) throw HostError.notFound }
            if (file.done) return stateOf(file)
            if (length == 0L) {
                // A part that is full but never got through complete: finish it.
                val current = partLength(file)
                if (current != file.size) throw HostError.offsetMismatch(current)
                complete(file, writer)
                return stateOf(file)
            }
            val part = files.existing(file.uri) ?: run {
                discard(file)
                throw HostError.notFound
            }
            if (part.size != offset) {
                body.discard(length)
                throw HostError.offsetMismatch(part.size)
            }
            if (offset == 0L) {
                writer.hashed = 0
                writer.digest = file.sha256?.let { MessageDigest.getInstance("SHA-256") }
            } else if (writer.hashed != offset) {
                writer.digest = null
            }
            var written = 0L
            val out = try {
                files.append(part)
            } catch (e: IOException) {
                throw failed(e)
            }
            var lastReport = 0L
            try {
                val buffer = ByteArray(256 * 1024)
                while (written < length) {
                    val n = body.read(buffer, 0, minOf(buffer.size.toLong(), length - written).toInt())
                    try {
                        out.write(buffer, 0, n)
                    } catch (e: IOException) {
                        throw failed(e)
                    }
                    writer.digest?.update(buffer, 0, n)
                    writer.hashed += n
                    written += n
                    val now = System.nanoTime()
                    if (now - lastReport > 250_000_000L) {
                        lastReport = now
                        onProgress(file, offset + written)
                    }
                }
            } finally {
                // A failed close shows as a short file, which the next request's offset check reports.
                runCatching { out.close() }
            }
            val end = offset + written
            file.updated = clock()
            if (end < file.size) {
                runCatching { save(file) }
                onProgress(file, end)
                return stateOf(file, end)
            }
            complete(file, writer)
            return stateOf(file)
        } finally {
            writer.stop = null
            writer.gate.release()
        }
    }

    /** Drops what a guest had begun and not finished, and the records of what it finished (it was removed). Received files stay. */
    fun removeDevice(deviceId: String) {
        val mine = synchronized(gate) { records.values.filter { it.deviceId == deviceId } }
        for (file in mine) {
            // A chunk still coming in is stopped first, so its part can be deleted.
            val writer = writers.computeIfAbsent(file.id) { Writer() }
            val held = takeOver(writer)
            try {
                discard(file)
            } finally {
                if (held) writer.gate.release()
            }
        }
    }

    // The request holding the writer may not have registered its abort yet, so it is asked again until the wait is over.
    private fun takeOver(writer: Writer): Boolean {
        val until = System.nanoTime() + TAKE_OVER_SECONDS * 1_000_000_000L
        while (!writer.gate.tryAcquire(100, TimeUnit.MILLISECONDS)) {
            writer.stop?.invoke()
            if (System.nanoTime() > until) return false
        }
        return true
    }

    // Finishes a file whose part is already full but never got through complete. Skipped while a chunk is being written.
    private fun finishIfFull(file: IncomingFile) {
        if (file.done || partLength(file) != file.size) return
        val writer = writers.computeIfAbsent(file.id) { Writer() }
        if (!writer.gate.tryAcquire()) return
        try {
            if (!file.done) complete(file, writer)
        } catch (e: HostError) {
            // Answered by the next request; a hash mismatch has removed the file.
        } finally {
            writer.gate.release()
        }
    }

    private fun complete(file: IncomingFile, writer: Writer?) {
        synchronized(gate) { if (!records.containsKey(file.id)) throw HostError.notFound }
        val uri = try {
            file.sha256?.let { expected ->
                val digest = writer?.digest
                val actual = if (digest != null && writer.hashed == file.size) hex(digest.digest()) else hashPart(file)
                if (actual != expected) {
                    discard(file)
                    throw HostError.hashMismatch
                }
            }
            files.finish(ReceivedFiles.Part(file.uri, file.size), file.modified)
        } catch (e: HostError) {
            throw e
        } catch (e: Exception) {
            throw failed(e)
        }
        // The file is in place: record that first, so nothing below can make the guest send it again. The index takes
        // the asset in the same step that stops tracking the transfer, under the lock begin decides with.
        var removed: Boolean
        var indexed = false
        synchronized(gate) {
            file.uri = uri
            file.done = true
            file.finished = clock()
            removed = !records.containsKey(file.id)
            if (!removed && file.sourceId != null) indexed = runCatching { index.add(file.deviceId, file.sourceId) }.isSuccess
            // The index answers for a gallery file from here on, so its record has nothing left to keep.
            if (indexed) records.remove(file.id)
            untrack(file)
        }
        writers.remove(file.id)
        // The guest was removed while the file was finishing: the file stays, nothing is announced or recorded.
        if (removed) return
        if (indexed) File(directory, "${file.id}.json").delete() else runCatching { save(file) }
        onFinished(file)
    }

    private fun hashPart(file: IncomingFile): String {
        val digest = MessageDigest.getInstance("SHA-256")
        files.read(file.uri).use { input ->
            val buffer = ByteArray(128 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        return hex(digest.digest())
    }

    private fun discard(file: IncomingFile) {
        if (!file.done && file.uri.isNotEmpty()) runCatching { files.discard(file.uri) }
        synchronized(gate) {
            records.remove(file.id)
            untrack(file)
        }
        writers.remove(file.id)
        File(directory, "${file.id}.json").delete()
    }

    // With the gate held.
    private fun untrack(file: IncomingFile) {
        val source = file.sourceId ?: return
        val key = file.deviceId to source
        if (bySource[key] === file) bySource.remove(key)
    }

    private fun isStale(file: IncomingFile, now: Long) =
        if (file.done) now - (file.finished ?: file.started) > DONE_KEPT_MS else now - file.updated > PART_KEPT_MS

    // Drops finished records older than a day and parts nobody has touched for a week, at most once an hour.
    private fun pruneIfDue(now: Long) {
        val stale = synchronized(gate) {
            if (now - lastPrune < HOUR_MS) return
            lastPrune = now
            records.values.filter { isStale(it, now) }
        }
        for (file in stale) {
            val writer = writers.computeIfAbsent(file.id) { Writer() }
            if (!writer.gate.tryAcquire()) continue
            try {
                discard(file)
            } finally {
                writer.gate.release()
            }
        }
    }

    private fun stateOf(file: IncomingFile, offset: Long? = null) =
        if (file.done) ItemState(file.id, file.size, true) else ItemState(file.id, offset ?: partLength(file), false)

    private fun partLength(file: IncomingFile): Long = files.existing(file.uri)?.size ?: 0

    private fun save(file: IncomingFile) = File(directory, "${file.id}.json").saveJson(file)

    private fun failed(e: Exception): HostError = HostError.serverError

    /** Reads the records left by a run before, and finishes or drops what they say. Slow (it may hash a file), so not on the main thread. */
    fun load() {
        val now = clock()
        lastPrune = now
        for (path in directory.listFiles { f -> f.name.endsWith(".json") }.orEmpty()) {
            val file = try {
                com.lazysend.lazysend.link.LinkJson.decodeFromString<IncomingFile>(path.readText())
            } catch (e: Exception) {
                path.delete()
                continue
            }
            if (!isValidId(file.id) || file.folder.isEmpty() || path.name != "${file.id}.json") {
                path.delete()
                continue
            }
            records[file.id] = file
            if (!file.done && file.sourceId != null) bySource[file.deviceId to file.sourceId] = file
            when {
                isStale(file, now) -> discard(file)
                !file.done && files.existing(file.uri) == null -> discard(file)
                else -> finishIfFull(file)
            }
        }
    }

    private companion object {
        const val TAKE_OVER_SECONDS = 5L
        const val HOUR_MS = 60 * 60 * 1000L
        const val DONE_KEPT_MS = 24 * HOUR_MS
        const val PART_KEPT_MS = 7 * DONE_KEPT_MS
        val MONTH: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM").withZone(ZoneId.systemDefault())

        // A guest can send any date; only plausible ones are kept.
        fun parseModified(text: String?): Long? {
            val instant = try {
                OffsetDateTime.parse(text ?: return null).toInstant()
            } catch (e: java.time.format.DateTimeParseException) {
                return null
            }
            val year = instant.atZone(ZoneId.of("UTC")).year
            return if (year in 1980..2100) instant.toEpochMilli() else null
        }
    }
}
