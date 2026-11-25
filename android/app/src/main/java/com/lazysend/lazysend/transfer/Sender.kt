package com.lazysend.lazysend.transfer

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import com.lazysend.lazysend.data.Direction
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.EntryState
import com.lazysend.lazysend.data.Pc
import com.lazysend.lazysend.data.Timeline
import com.lazysend.lazysend.data.TimelineEntry
import com.lazysend.lazysend.link.DataSource
import com.lazysend.lazysend.host.CLIP_MAX_AGE_MS
import com.lazysend.lazysend.link.ItemRequest
import com.lazysend.lazysend.link.LinkClient
import com.lazysend.lazysend.link.LinkException
import com.lazysend.lazysend.link.Uploader
import com.lazysend.lazysend.link.missingIds
import com.lazysend.lazysend.link.newSendId
import com.lazysend.lazysend.link.sha256Hex
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** The most a note can hold; a larger text goes as a file. */
const val MAX_NOTE_BYTES = 1024 * 1024

fun noteTooLong(text: String) = text.toByteArray().size > MAX_NOTE_BYTES

/** The id of a library row is this and the id of its computer. */
const val GALLERY_ROW = "gallery-"

fun galleryPcOf(rowId: String) = rowId.removePrefix(GALLERY_ROW)

/** What the foreground notification of a running send shows. */
data class SendProgress(val title: String, val text: String, val done: Long, val total: Long)

/** Sends text, links, files and the gallery to a PC and keeps the timeline up to date. One upload runs at a time. */
class Sender(
    private val context: Context,
    private val connector: PcConnector,
    private val timeline: Timeline,
    private val assets: MediaAssets,
    private val clock: () -> Long = System::currentTimeMillis,
    val outgoing: Outgoing = Outgoing(File(context.noBackupFilesDir, "outgoing")),
) {
    /** Sends that are being uploaded now, so a second ask for one does nothing. */
    private val uploading = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    private val queue = Mutex()
    private val running = MutableStateFlow(0)
    private val shown = MutableStateFlow<SendProgress?>(null)

    /** How many sends are running or waiting for their turn. */
    val busy: StateFlow<Int> get() = running
    val progress: StateFlow<SendProgress?> get() = shown

    // A shot or paste is only worth putting on the clipboard while it is fresh; [at] is when it was made.
    private fun stillFresh(at: Long) = clock() - at <= CLIP_MAX_AGE_MS

    /** Sends a note; a lone http(s) address goes as a link. Returns the reason when it did not arrive. */
    suspend fun sendText(pc: Pc, text: String, clip: Boolean = false, at: Long = clock()): String? {
        val trimmed = text.trim()
        val isLink = trimmed.length <= 8192 && Regex("https?://\\S+").matches(trimmed)
        val sendId = newSendId()
        val item = if (isLink) ItemRequest("link", url = trimmed, sendId = sendId, clip = clip.takeIf { it }) else ItemRequest("text", text = text, sendId = sendId, clip = clip.takeIf { it })
        if (noteTooLong(text)) return "That is more than the 1 MB a note can hold. Send it as a file instead."
        val entry = TimelineEntry(
            UUID.randomUUID().toString(), clock(), Direction.Sent, if (isLink) EntryKind.Link else EntryKind.Text, pc.name,
            if (isLink) trimmed else text, state = EntryState.Active, clip = clip,
        )
        timeline.add(entry)
        return try {
            val reached = connector.connect(pc, userAction = true).reachedOrNull() ?: throw IOException("${pc.name} is not reachable.")
            val fresh = clip && stillFresh(at)
            reached.postItem(item.copy(clip = fresh.takeIf { it }))
            timeline.update(entry.id) { it.copy(state = EntryState.Done, clip = fresh) }
            null
        } catch (e: IOException) {
            timeline.update(entry.id) { it.copy(state = EntryState.Failed, detail = e.message.orEmpty()) }
            e.message ?: "Not sent."
        } catch (e: LinkException) {
            timeline.update(entry.id) { it.copy(state = EntryState.Failed, detail = e.message.orEmpty()) }
            e.message
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            timeline.update(entry.id) { it.copy(state = EntryState.Failed, detail = e.message.orEmpty()) }
            e.message ?: "Not sent."
        } finally {
            timeline.save()
        }
    }

    /** A clipped send (a camera shot or a paste) does not wait behind a gallery sync or a big file: it runs alongside them. */
    suspend fun sendFiles(pc: Pc, uris: List<Uri>, clip: Boolean = false, at: Long = clock()) = exclusive(alongside = clip) {
        for (uri in uris) stage(pc, uri, clip, at)?.let { upload(it) }
        if (!clip) shown.value = null
    }

    /**
     * Copies a file into the app's own folder and puts its row in the list, so what goes wrong later cannot lose it. Returns
     * null, with the row failed, when the file could not be read. The upload is [sendStaged].
     */
    suspend fun stage(pc: Pc, uri: Uri, clip: Boolean, at: Long): OutgoingSend? {
        val id = UUID.randomUUID().toString()
        timeline.add(
            TimelineEntry(id, clock(), Direction.Sent, EntryKind.File, pc.name, uri.lastPathSegment ?: "file", state = EntryState.Active, clip = clip),
        )
        return try {
            withContext(Dispatchers.IO) {
                val meta = describe(uri)
                timeline.update(id) { it.copy(title = meta.name, totalBytes = meta.size, mime = meta.mime) }
                val send = OutgoingSend(id, pc.id, meta.name, meta.size, meta.mime, meta.modified, clip, at, newSendId())
                val kept = (context.contentResolver.openInputStream(uri) ?: throw IOException("Cannot open $uri")).use { outgoing.add(send, it) }
                timeline.update(id) { it.copy(state = EntryState.Paused, totalBytes = kept.size) }
                kept
            }
        } catch (e: CancellationException) {
            timeline.update(id) { it.copy(state = EntryState.Failed, detail = "Not copied") }
            throw e
        } catch (e: Exception) {
            timeline.update(id) { it.copy(state = EntryState.Failed, detail = e.message.orEmpty()) }
            null
        } finally {
            timeline.save()
        }
    }

    /** Uploads what [stage] kept; the same for a row that is sent again. */
    suspend fun sendStaged(id: String) {
        val send = outgoing.get(id) ?: return failGone(id)
        exclusive(alongside = send.clip) { upload(send) }
    }

    /** Sends everything that is still waiting. */
    suspend fun resumePending() {
        for (send in outgoing.pending.toList()) {
            if (timeline.get(send.id) == null) {
                outgoing.remove(send.id)
                continue
            }
            if (send.id !in uploading) sendStaged(send.id)
        }
    }

    private fun failGone(id: String) {
        timeline.update(id) { it.copy(state = EntryState.Failed, detail = "The file is not kept any more") }
        timeline.save()
    }

    suspend fun syncGallery(pc: Pc) = exclusive { gallery(pc) }

    private suspend fun exclusive(alongside: Boolean = false, block: suspend () -> Unit) {
        running.update { it + 1 }
        try {
            if (alongside) block() else queue.withLock { block() }
        } finally {
            running.update { it - 1 }
            if (!alongside) shown.value = null
        }
    }

    private fun Reach.reachedOrNull(): LinkClient? = (this as? Reach.Reached)?.client

    private fun refresher(pc: Pc, first: LinkClient): suspend () -> LinkClient {
        var current: LinkClient? = first
        return {
            current?.also { current = null }
                ?: connector.connect(pc, search = false).reachedOrNull()
                ?: throw IOException("${pc.name} is not reachable.")
        }
    }

    private suspend fun upload(send: OutgoingSend) {
        val id = send.id
        if (!uploading.add(id)) return
        var sentTo: Pc? = null
        try {
            // Another run of the same row may have delivered it while this one waited for its turn.
            if (outgoing.get(id) == null) return
            val pc = connector.pc(send.pcId)
            if (pc == null) {
                outgoing.remove(id)
                timeline.update(id) { it.copy(state = EntryState.Failed, detail = "This device is not paired any more") }
                return
            }
            sentTo = pc
            timeline.update(id) { it.copy(state = EntryState.Active, detail = "") }
            val file = outgoing.file(send)
            val first = connector.connect(pc, userAction = true)
            if (first == Reach.Forgotten) return forgottenBy(pc, id)
            val reached = first.reachedOrNull() ?: throw IOException("${pc.name} is not reachable.")
            val source = DataSource { offset -> openCopy(file, offset) }
            if (!send.clip) shown.value = SendProgress(send.name, pc.name, 0, send.size)
            val hash = withContext(Dispatchers.IO) { sha256Hex(source) }
            val fresh = send.clip && stillFresh(send.at)
            timeline.update(id) { it.copy(clip = fresh) }
            val request = ItemRequest("file", name = send.name, size = send.size, mime = send.mime, modified = send.modified, sha256 = hash, sendId = send.sendId, clip = fresh.takeIf { it })
            var lastReport = 0L
            Uploader(refresher(pc, reached)).sendFile(request, source) { sent ->
                val now = System.nanoTime()
                if (now - lastReport > 250_000_000L || sent == send.size) {
                    lastReport = now
                    timeline.update(id) { it.copy(bytes = sent) }
                    if (!send.clip) shown.value = SendProgress(send.name, pc.name, sent, send.size)
                }
            }
            outgoing.remove(id)
            timeline.update(id) { it.copy(state = EntryState.Done, bytes = send.size) }
        } catch (e: CancellationException) {
            timeline.update(id) { it.copy(state = EntryState.Paused) }
            throw e
        } catch (e: LinkException) {
            if (e.status == 401 && sentTo != null) forgottenBy(sentTo, id)
            else timeline.update(id) { it.copy(state = EntryState.Failed, detail = e.message.orEmpty()) }
        } catch (e: Exception) {
            // A file that cannot be read, a PC that cannot be reached and a refusal all end this one attempt, not the app; the copy stays.
            timeline.update(id) { it.copy(state = EntryState.Failed, detail = e.message.orEmpty()) }
        } finally {
            uploading.remove(id)
            timeline.save()
        }
    }

    /** The PC does not know this phone any more: it is dropped, what waited for it fails, and the rows say why. */
    private fun forgottenBy(pc: Pc, id: String) {
        // Pairing again in the meantime replaced the secret; the refusal was for the old one and the computer stays.
        if (connector.pc(pc.id)?.secret != pc.secret) {
            timeline.update(id) { it.copy(state = EntryState.Failed, detail = "Pairing changed while this was sent. Send it again.") }
            return
        }
        connector.forgotten(pc)
        val reason = "${pc.name} no longer knows this phone."
        for (send in outgoing.pending.filter { it.pcId == pc.id }) {
            outgoing.remove(send.id)
            timeline.update(send.id) { it.copy(state = EntryState.Failed, detail = reason) }
        }
        timeline.update(id) { it.copy(state = EntryState.Failed, detail = reason) }
    }

    private fun openCopy(file: File, offset: Long): InputStream {
        val input = file.inputStream()
        if (offset > 0) input.channel.position(offset)
        return input
    }

    private suspend fun gallery(pc: Pc) {
        val id = GALLERY_ROW + pc.id
        val previous = timeline.get(id)
        timeline.add(
            TimelineEntry(
                id, clock(), Direction.Sent, EntryKind.Gallery, pc.name, "Photos and videos", detail = "Looking for what is new",
                state = EntryState.Active, count = previous?.count ?: 0, totalCount = previous?.totalCount ?: 0,
            ),
        )
        fun paused(detail: String) = timeline.update(id) { it.copy(state = EntryState.Paused, detail = detail) }
        try {
            val all = withContext(Dispatchers.IO) { assets.list() }
            var reached = connector.awaitReachable(pc) ?: return galleryForgotten(pc, id)
            var todo: List<Asset>
            while (true) {
                try {
                    val missing = reached.client.missingIds(all.map { it.sourceId }).toSet()
                    todo = all.filter { it.sourceId in missing }
                    break
                } catch (e: LinkException) {
                    if (e.status == 401) return galleryForgotten(pc, id)
                    throw e
                } catch (e: IOException) {
                    paused("Waiting for ${pc.name}")
                    reached = connector.awaitReachable(pc) ?: return galleryForgotten(pc, id)
                }
            }
            val totalBytes = todo.sumOf { it.size }
            var sentBytes = 0L
            var sentCount = all.size - todo.size
            var failed = 0
            timeline.update(id) {
                it.copy(state = EntryState.Active, detail = "", count = sentCount, totalCount = all.size, bytes = 0, totalBytes = totalBytes)
            }
            for (asset in todo) {
                // Read before anything goes over the network: a photo deleted or no longer allowed is skipped, not retried.
                val request = try {
                    ItemRequest(
                        "file", name = asset.name, size = asset.size, mime = asset.mime,
                        modified = Instant.ofEpochMilli(asset.modifiedMs).toString(), sourceId = asset.sourceId,
                        sha256 = withContext(Dispatchers.IO) { sha256Hex { offset -> open(asset.uri, offset) } },
                    )
                } catch (e: IOException) {
                    null
                } catch (e: SecurityException) {
                    null
                }
                if (request == null) {
                    failed++
                    continue
                }
                var done = false
                while (!done) {
                    try {
                        var lastReport = 0L
                        Uploader(refresher(pc, reached.client)).sendFile(request, { offset -> open(asset.uri, offset) }) { sent ->
                            val now = System.nanoTime()
                            if (now - lastReport > 250_000_000L) {
                                lastReport = now
                                report(id, pc, reached.link, sentCount, all.size, sentBytes + sent, totalBytes)
                            }
                        }
                        done = true
                    } catch (e: IOException) {
                        paused("Waiting for ${pc.name}")
                        shown.value = SendProgress("Photos and videos", "Waiting for ${pc.name}", sentBytes, totalBytes)
                        reached = connector.awaitReachable(pc) ?: return galleryForgotten(pc, id)
                        timeline.update(id) { it.copy(state = EntryState.Active, detail = "") }
                    } catch (e: LinkException) {
                        if (e.status == 401) return galleryForgotten(pc, id)
                        if (e.code == "diskFull") return failGallery(id, e.message.orEmpty())
                        failed++
                        done = true
                    }
                }
                sentBytes += asset.size
                sentCount++
                report(id, pc, reached.link, sentCount, all.size, sentBytes, totalBytes)
                if (sentCount % 20 == 0) timeline.save()
            }
            timeline.update(id) {
                it.copy(
                    state = EntryState.Done, time = clock(), count = sentCount, bytes = totalBytes,
                    detail = if (failed > 0) "$failed could not be sent" else "",
                )
            }
        } catch (e: CancellationException) {
            timeline.update(id) { it.copy(state = EntryState.Paused, detail = "Stopped") }
            throw e
        } catch (e: Exception) {
            failGallery(id, e.message ?: "Could not read the photos.")
        } finally {
            timeline.save()
        }
    }

    private fun report(id: String, pc: Pc, link: LinkKind, count: Int, totalCount: Int, bytes: Long, totalBytes: Long) {
        timeline.update(id) { it.copy(count = count, totalCount = totalCount, bytes = bytes, totalBytes = totalBytes) }
        shown.value = SendProgress(
            "Sending photos and videos", "${count + 1} of $totalCount · ${formatBytes(bytes)} of ${formatBytes(totalBytes)} · ${link.label}", bytes, totalBytes,
        )
    }

    /** The run stops at once and the PC leaves the list, instead of every photo being posted to be refused. */
    private fun galleryForgotten(pc: Pc, id: String) {
        if (connector.pc(pc.id) != null) forgottenBy(pc, id) else failGallery(id, "${pc.name} no longer knows this phone.")
    }

    private fun failGallery(id: String, reason: String) {
        timeline.update(id) { it.copy(state = EntryState.Failed, detail = reason) }
    }

    private class Meta(val name: String, val size: Long, val mime: String?, val modified: String?)

    private fun describe(uri: Uri): Meta {
        var name = uri.lastPathSegment ?: "file"
        var size = -1L
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
            if (it.moveToFirst()) {
                it.getString(0)?.let { n -> name = n }
                if (!it.isNull(1)) size = it.getLong(1)
            }
        }
        if (size < 0) size = context.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: 0
        return Meta(name, size, context.contentResolver.getType(uri), null)
    }

    private fun open(uri: Uri, offset: Long): InputStream {
        val input = ParcelFileDescriptor.AutoCloseInputStream(context.contentResolver.openFileDescriptor(uri, "r") ?: throw IOException("Cannot open $uri"))
        if (offset > 0) {
            try {
                input.channel.position(offset)
            } catch (e: IOException) {
                var left = offset
                while (left > 0) left -= input.skip(left).also { if (it <= 0) throw IOException("Cannot skip in $uri") }
            }
        }
        return input
    }
}
