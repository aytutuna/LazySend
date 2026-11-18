package com.lazysend.lazysend.transfer

import com.lazysend.lazysend.data.Direction
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.EntryState
import com.lazysend.lazysend.data.Pc
import com.lazysend.lazysend.data.Timeline
import com.lazysend.lazysend.data.TimelineEntry
import com.lazysend.lazysend.host.GalleryIndex
import com.lazysend.lazysend.host.MONTH
import com.lazysend.lazysend.host.cleanFileName
import com.lazysend.lazysend.host.isValidSourceId
import com.lazysend.lazysend.host.parseModified
import com.lazysend.lazysend.link.LinkClient
import com.lazysend.lazysend.link.LinkException
import com.lazysend.lazysend.link.MAX_OUTBOX_WAIT
import com.lazysend.lazysend.link.OutboxEntry
import java.io.IOException
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.coroutines.coroutineContext

private const val GALLERY_SAVE_EVERY = 20

/** This phone has no room left. The item stays queued on the PC and is asked for again later. */
class StorageFullException(cause: IOException) : IOException(cause.message, cause)

internal fun isOutOfSpace(e: IOException): Boolean = e.message.orEmpty().let { "ENOSPC" in it || "No space left" in it }

/** Takes what the PC has queued for this phone: text and links into the timeline, files into the media store. */
class Receiver(
    private val connector: PcConnector,
    private val timeline: Timeline,
    private val files: ReceivedFiles,
    private val gallery: GalleryIndex,
    private val galleryParts: GalleryParts,
    private val notify: (id: Int, title: String, text: String) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    // The foreground watch and the periodic check can both ask for the same item; one at a time per PC keeps them off each other's file.
    private val locks = ConcurrentHashMap<String, Mutex>()

    // Gallery files have no timeline entry of their own: a download that dropped carries on from the part in galleryParts,
    // and the assets received are in the gallery index, so a repeat of one is only acknowledged.
    @Volatile private var galleryUnsaved = false

    // Said once until a file gets through, as the item is asked for again every little while.
    @Volatile private var fullTold = false

    /** Takes everything pending on [pc] once; with [wait] above 0 it holds the request open until something comes. */
    suspend fun collect(pc: Pc, client: LinkClient, wait: Int): Int {
        var taken = 0
        do {
            val reply = client.outbox(wait.coerceAtMost(MAX_OUTBOX_WAIT))
            locks.getOrPut(pc.id) { Mutex() }.withLock {
                try {
                    for (item in reply.items) {
                        try {
                            take(pc, client, item)
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: IOException) {
                            throw if (isOutOfSpace(e)) storageFull(pc, e) else e
                        } catch (e: LinkException) {
                            // The PC is busy or failing: leave the item queued and try again later. Anything else will not get better.
                            if (e.status == 401 || e.status == 429 || e.status >= 500 || e.code == "busy") throw e
                            fail(pc, item, e.message)
                        } catch (e: Exception) {
                            // One item that cannot be stored must not stop the ones behind it.
                            fail(pc, item, e.message)
                        }
                        client.acknowledge(item.id)
                        taken++
                    }
                } finally {
                    // The gallery row is written every 20 files, so the last few are written here.
                    if (galleryUnsaved) {
                        galleryUnsaved = false
                        timeline.save()
                    }
                }
            }
        } while (reply.more == true)
        return taken
    }

    /** Keeps asking the PC for items until the caller cancels it or the PC no longer knows this phone. */
    suspend fun watch(pc: Pc) {
        while (true) {
            coroutineContext.ensureActive()
            val reached = connector.awaitReachable(pc) ?: return
            try {
                while (true) collect(pc, reached.client, MAX_OUTBOX_WAIT)
            } catch (e: LinkException) {
                if (e.status == 401) return
                delay(5000)
            } catch (e: StorageFullException) {
                delay(30_000)
            } catch (e: IOException) {
                connector.lost(pc.id)
                delay(2000)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                delay(5000)
            }
        }
    }

    private fun storageFull(pc: Pc, e: IOException): StorageFullException {
        if (!fullTold) {
            fullTold = true
            notify("storage-full".hashCode(), pc.name, "This phone is out of storage. Files stay queued on ${pc.name} until there is room.")
        }
        return StorageFullException(e)
    }

    private fun fail(pc: Pc, item: OutboxEntry, reason: String?) {
        val id = "in-${item.id}"
        timeline.get(id)?.uri?.let(files::discard)
        galleryParts.remove("${pc.id}/${item.id}")?.let(files::discard)
        val entry = TimelineEntry(
            id, clock(), Direction.Received, if (item.kind == "file") EntryKind.File else EntryKind.Text, pc.name,
            item.name ?: item.text ?: item.url ?: "", state = EntryState.Failed, detail = reason.orEmpty(),
        )
        if (timeline.get(id) == null) timeline.add(entry) else timeline.update(id) { it.copy(state = EntryState.Failed, detail = reason.orEmpty(), uri = null) }
        timeline.save()
    }

    private suspend fun take(pc: Pc, client: LinkClient, item: OutboxEntry) {
        val id = "in-${item.id}"
        if (timeline.get(id)?.state == EntryState.Done) return
        when (item.kind) {
            "text", "link" -> {
                val body = item.text ?: item.url ?: return
                val kind = if (item.kind == "link") EntryKind.Link else EntryKind.Text
                timeline.add(TimelineEntry(id, clock(), Direction.Received, kind, pc.name, body, state = EntryState.Done, clip = item.clip == true))
                notify(id.hashCode(), pc.name, body)
            }
            "file" -> if (isValidSourceId(item.sourceId)) downloadGalleryFile(pc, client, item) else downloadFile(pc, client, item, id)
        }
    }

    /** A file from the host's photo library: filed by the month it was taken, and counted in one row for the host. */
    private suspend fun downloadGalleryFile(pc: Pc, client: LinkClient, item: OutboxEntry) {
        val source = item.sourceId!!
        if (gallery.contains(pc.id, source)) return
        val key = "${pc.id}/${item.id}"
        val name = cleanFileName(item.name)
        val size = item.size ?: 0
        val taken = parseModified(item.taken)
        val folder = cleanFileName(pc.name, "Computer") + "/Gallery/" + MONTH.format(Instant.ofEpochMilli(taken ?: clock()))
        var part = galleryParts.get(key)?.let(files::existing) ?: files.create(name, item.mime, folder)
        if (part.size > size) {
            files.discard(part.uri)
            part = files.create(name, item.mime, folder)
        }
        galleryParts.put(key, part.uri)
        // A half-saved file that already holds every byte only needs putting in place.
        if (part.size < size) part = download(client, item, name, folder, part) { moved, _ -> galleryParts.put(key, moved.uri) }
        files.finish(part, taken)
        fullTold = false
        gallery.add(pc.id, source)
        galleryParts.remove(key)
        val row = "gallery-from-${pc.id}"
        val before = timeline.get(row)
        if (before == null) {
            timeline.add(TimelineEntry(row, clock(), Direction.Received, EntryKind.Gallery, pc.name, "Photos and videos", state = EntryState.Done, count = 1, bytes = size))
        } else {
            timeline.update(row) { it.copy(time = clock(), count = it.count + 1, bytes = it.bytes + size) }
            if ((before.count + 1) % GALLERY_SAVE_EVERY == 0) timeline.save() else galleryUnsaved = true
        }
    }

    /** The PC was removed: what it had begun is deleted and its received assets are forgotten. */
    fun forget(pcId: String) {
        galleryParts.removeAll(pcId).forEach(files::discard)
        gallery.clear(pcId)
    }

    private suspend fun downloadFile(pc: Pc, client: LinkClient, item: OutboxEntry, id: String) {
        val name = cleanFileName(item.name)
        val size = item.size ?: 0
        val previous = timeline.get(id)
        var part = previous?.uri?.let(files::existing) ?: files.create(name, item.mime)
        if (part.size > size) {
            files.discard(part.uri)
            part = files.create(name, item.mime)
        }
        timeline.add(
            TimelineEntry(
                id, previous?.time ?: clock(), Direction.Received, EntryKind.File, pc.name, name,
                state = EntryState.Active, bytes = part.size, totalBytes = size, uri = part.uri, mime = item.mime, clip = item.clip == true && previous == null,
            ),
        )
        try {
            // A half-saved file that already holds every byte only needs putting in place.
            if (part.size < size) part = download(client, item, name, "", part) { moved, bytes -> timeline.update(id) { it.copy(uri = moved.uri, bytes = bytes) } }
        } catch (e: IOException) {
            timeline.update(id) { it.copy(state = EntryState.Paused) }
            timeline.save()
            throw e
        }
        val saved = files.finish(part)
        fullTold = false
        timeline.update(id) { it.copy(state = EntryState.Done, bytes = size, uri = saved) }
        timeline.save()
        notify(id.hashCode(), pc.name, name)
    }

    private suspend fun download(
        client: LinkClient,
        item: OutboxEntry,
        name: String,
        folder: String,
        start: ReceivedFiles.Part,
        track: (part: ReceivedFiles.Part, bytes: Long) -> Unit,
    ): ReceivedFiles.Part {
        var part = start
        client.download(item.id, part.size).use { download ->
            if (download.status == 200 && part.size > 0) {
                files.discard(part.uri)
                part = files.create(name, item.mime, folder)
                track(part, 0)
            }
            var written = part.size
            var lastReport = 0L
            files.append(part).use { out ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val n = download.body.read(buffer)
                    if (n < 0) break
                    out.write(buffer, 0, n)
                    written += n
                    val now = System.nanoTime()
                    if (now - lastReport > 250_000_000L) {
                        lastReport = now
                        track(part, written)
                    }
                }
            }
            if (written != download.size) throw IOException("The download stopped early.")
        }
        return part
    }
}
