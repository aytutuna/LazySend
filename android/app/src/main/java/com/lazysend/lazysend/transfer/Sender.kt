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
import com.lazysend.lazysend.link.ItemRequest
import com.lazysend.lazysend.link.LinkClient
import com.lazysend.lazysend.link.LinkException
import com.lazysend.lazysend.link.Uploader
import com.lazysend.lazysend.link.missingIds
import com.lazysend.lazysend.link.sha256Hex
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

/** What the foreground notification of a running send shows. */
data class SendProgress(val title: String, val text: String, val done: Long, val total: Long)

/** Sends text, links, files and the gallery to a PC and keeps the timeline up to date. One upload runs at a time. */
class Sender(
    private val context: Context,
    private val connector: PcConnector,
    private val timeline: Timeline,
    private val assets: MediaAssets,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val queue = Mutex()
    private val running = MutableStateFlow(0)
    private val shown = MutableStateFlow<SendProgress?>(null)

    /** How many sends are running or waiting for their turn. */
    val busy: StateFlow<Int> get() = running
    val progress: StateFlow<SendProgress?> get() = shown

    /** Sends a note; a lone http(s) address goes as a link. Returns the reason when it did not arrive. */
    suspend fun sendText(pc: Pc, text: String): String? {
        val trimmed = text.trim()
        val isLink = trimmed.length <= 8192 && Regex("https?://\\S+").matches(trimmed)
        val item = if (isLink) ItemRequest("link", url = trimmed) else ItemRequest("text", text = text)
        if (text.toByteArray().size > 1024 * 1024) return "That is more than the 1 MB a note can hold. Send it as a file instead."
        val entry = TimelineEntry(
            UUID.randomUUID().toString(), clock(), Direction.Sent, if (isLink) EntryKind.Link else EntryKind.Text, pc.name,
            if (isLink) trimmed else text, state = EntryState.Active,
        )
        timeline.add(entry)
        return try {
            val reached = connector.connect(pc, userAction = true).reachedOrNull() ?: throw IOException("${pc.name} is not reachable.")
            reached.postItem(item)
            timeline.update(entry.id) { it.copy(state = EntryState.Done) }
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

    suspend fun sendFiles(pc: Pc, uris: List<Uri>) = exclusive {
        for (uri in uris) sendOne(pc, uri)
        shown.value = null
    }

    suspend fun syncGallery(pc: Pc) = exclusive { gallery(pc) }

    private suspend fun exclusive(block: suspend () -> Unit) {
        running.update { it + 1 }
        try {
            queue.withLock { block() }
        } finally {
            running.update { it - 1 }
            shown.value = null
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

    private suspend fun sendOne(pc: Pc, uri: Uri) {
        val id = UUID.randomUUID().toString()
        timeline.add(TimelineEntry(id, clock(), Direction.Sent, EntryKind.File, pc.name, uri.lastPathSegment ?: "file", state = EntryState.Active))
        try {
            val meta = withContext(Dispatchers.IO) { describe(uri) }
            timeline.update(id) { it.copy(title = meta.name, totalBytes = meta.size, mime = meta.mime) }
            val first = connector.connect(pc, userAction = true).reachedOrNull() ?: throw IOException("${pc.name} is not reachable.")
            val source = DataSource { offset -> open(uri, offset) }
            shown.value = SendProgress(meta.name, pc.name, 0, meta.size)
            val hash = withContext(Dispatchers.IO) { sha256Hex(source) }
            val request = ItemRequest("file", name = meta.name, size = meta.size, mime = meta.mime, modified = meta.modified, sha256 = hash)
            var lastReport = 0L
            Uploader(refresher(pc, first)).sendFile(request, source) { sent ->
                val now = System.nanoTime()
                if (now - lastReport > 250_000_000L || sent == meta.size) {
                    lastReport = now
                    timeline.update(id) { it.copy(bytes = sent) }
                    shown.value = SendProgress(meta.name, pc.name, sent, meta.size)
                }
            }
            timeline.update(id) { it.copy(state = EntryState.Done, bytes = meta.size) }
        } catch (e: CancellationException) {
            timeline.update(id) { it.copy(state = EntryState.Paused) }
            throw e
        } catch (e: Exception) {
            // A file that cannot be read, a PC that cannot be reached and a refusal all end this one file, not the app.
            timeline.update(id) { it.copy(state = EntryState.Failed, detail = e.message.orEmpty()) }
        } finally {
            timeline.save()
        }
    }

    private suspend fun gallery(pc: Pc) {
        val id = "gallery-${pc.id}"
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
            var reached = connector.awaitReachable(pc) ?: return failGallery(id, "${pc.name} no longer knows this phone.")
            var todo: List<Asset>
            while (true) {
                try {
                    val missing = reached.client.missingIds(all.map { it.sourceId }).toSet()
                    todo = all.filter { it.sourceId in missing }
                    break
                } catch (e: IOException) {
                    paused("Waiting for ${pc.name}")
                    reached = connector.awaitReachable(pc) ?: return failGallery(id, "${pc.name} no longer knows this phone.")
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
                        reached = connector.awaitReachable(pc) ?: return failGallery(id, "${pc.name} no longer knows this phone.")
                        timeline.update(id) { it.copy(state = EntryState.Active, detail = "") }
                    } catch (e: LinkException) {
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
