package com.lazysend.lazysend.transfer

import com.lazysend.lazysend.data.Direction
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.EntryState
import com.lazysend.lazysend.data.Pc
import com.lazysend.lazysend.data.Timeline
import com.lazysend.lazysend.data.TimelineEntry
import com.lazysend.lazysend.link.LinkClient
import com.lazysend.lazysend.link.LinkException
import com.lazysend.lazysend.link.MAX_OUTBOX_WAIT
import com.lazysend.lazysend.link.OutboxEntry
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.coroutines.coroutineContext

/** Takes what the PC has queued for this phone: text and links into the timeline, files into the media store. */
class Receiver(
    private val connector: PcConnector,
    private val timeline: Timeline,
    private val files: ReceivedFiles,
    private val notify: (id: Int, title: String, text: String) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    // The foreground watch and the periodic check can both ask for the same item; one at a time per PC keeps them off each other's file.
    private val locks = ConcurrentHashMap<String, Mutex>()

    /** Takes everything pending on [pc] once; with [wait] above 0 it holds the request open until something comes. */
    suspend fun collect(pc: Pc, client: LinkClient, wait: Int): Int {
        var taken = 0
        do {
            val reply = client.outbox(wait.coerceAtMost(MAX_OUTBOX_WAIT))
            locks.getOrPut(pc.id) { Mutex() }.withLock {
                for (item in reply.items) {
                    try {
                        take(pc, client, item)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: IOException) {
                        throw e
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

    private fun fail(pc: Pc, item: OutboxEntry, reason: String?) {
        val id = "in-${item.id}"
        timeline.get(id)?.uri?.let(files::discard)
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
                timeline.add(TimelineEntry(id, clock(), Direction.Received, kind, pc.name, body, state = EntryState.Done))
                notify(id.hashCode(), pc.name, body)
            }
            "file" -> downloadFile(pc, client, item, id)
        }
    }

    private suspend fun downloadFile(pc: Pc, client: LinkClient, item: OutboxEntry, id: String) {
        val name = item.name ?: "file"
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
                state = EntryState.Active, bytes = part.size, totalBytes = size, uri = part.uri, mime = item.mime,
            ),
        )
        try {
            // A half-saved file that already holds every byte only needs putting in place.
            if (part.size < size) part = download(client, item, id, part)
        } catch (e: IOException) {
            timeline.update(id) { it.copy(state = EntryState.Paused) }
            timeline.save()
            throw e
        }
        val saved = files.finish(part)
        timeline.update(id) { it.copy(state = EntryState.Done, bytes = size, uri = saved) }
        timeline.save()
        notify(id.hashCode(), pc.name, name)
    }

    private suspend fun download(client: LinkClient, item: OutboxEntry, id: String, start: ReceivedFiles.Part): ReceivedFiles.Part {
        var part = start
        client.download(item.id, part.size).use { download ->
            if (download.status == 200 && part.size > 0) {
                files.discard(part.uri)
                part = files.create(item.name ?: "file", item.mime)
                timeline.update(id) { it.copy(uri = part.uri, bytes = 0) }
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
                        timeline.update(id) { it.copy(bytes = written) }
                    }
                }
            }
            if (written != download.size) throw IOException("The download stopped early.")
        }
        return part
    }
}
