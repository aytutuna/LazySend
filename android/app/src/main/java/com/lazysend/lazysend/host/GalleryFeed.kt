package com.lazysend.lazysend.host

import com.lazysend.lazysend.transfer.Asset
import java.io.File
import java.io.InputStream
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable

data class FeedProgress(val sent: Int, val total: Int, val done: Boolean, val lowStorage: Boolean = false)

@Serializable
private data class FeedRun(val total: Int, val base: Int, val done: Boolean = false)

@Serializable
private data class FeedFile(val runs: Map<String, FeedRun> = emptyMap())

const val FEED_QUEUE_LIMIT = 20

/**
 * Feeds this phone's photo library into a guest's outbox, a few files at a time: a file is copied into the outbox only
 * when it is queued, and the copy goes when the guest acknowledges it. What a guest has acknowledged is kept in [sent],
 * so a later run sends only what is new. [assets] is null while the app may not read the library.
 */
class GalleryFeed(
    private val outbox: Outbox,
    private val sent: GalleryIndex,
    private val file: File,
    private val scope: CoroutineScope,
    private val assets: () -> List<Asset>?,
    private val open: (Asset) -> InputStream,
    private val retryMs: Long = 30_000,
) {
    private var runs = loadJson(file) { FeedFile() }.runs
    // What is left to queue for each running guest, in the library's order.
    private val lists = HashMap<String, ArrayDeque<Asset>>()
    private val low = HashSet<String>()
    private val locks = ConcurrentHashMap<String, Mutex>()
    private val shown = MutableStateFlow<Map<String, FeedProgress>>(emptyMap())

    val progress: StateFlow<Map<String, FeedProgress>> get() = shown

    init {
        outbox.onAcknowledged = ::acknowledged
        publish()
    }

    @Synchronized
    fun running(): Set<String> = runs.filterValues { !it.done }.keys

    @Synchronized
    private fun active(deviceId: String) = runs[deviceId]?.done == false

    /** Starts a run for the guest unless one is going; does nothing while the library cannot be read. */
    fun start(deviceId: String): Job = scope.launch {
        if (active(deviceId)) return@launch
        val todo = candidates(deviceId) ?: return@launch
        synchronized(this@GalleryFeed) {
            runs = runs + (deviceId to FeedRun(todo.size, sent.count(deviceId)))
            lists[deviceId] = ArrayDeque(todo)
            save()
        }
        publish()
        fill(deviceId)
    }

    /** Carries on the runs that were going when the app was closed. */
    fun resume(): Job = scope.launch {
        for (deviceId in running()) {
            launch {
                if (synchronized(this@GalleryFeed) { lists[deviceId] } == null) {
                    val todo = candidates(deviceId) ?: return@launch
                    synchronized(this@GalleryFeed) { if (active(deviceId)) lists[deviceId] = ArrayDeque(todo) }
                }
                fill(deviceId)
            }
        }
    }

    /** Ends the run and takes back what was queued and not yet acknowledged, with its copies. */
    fun stop(deviceId: String) {
        synchronized(this) {
            runs = runs - deviceId
            lists.remove(deviceId)
            low.remove(deviceId)
            save()
        }
        outbox.removeGalleryItems(deviceId)
        publish()
    }

    /** The guest is gone: its run, its queue, its copies and the list of what it has. */
    fun forget(deviceId: String) {
        stop(deviceId)
        sent.clear(deviceId)
    }

    /** Drops what belongs to guests that are no longer paired. */
    fun reconcile(paired: Set<String>) {
        synchronized(this) { runs.keys.filter { it !in paired } }.forEach(::forget)
    }

    private fun acknowledged(item: OutboxItem) {
        val id = item.sourceId ?: return
        if (isValidSourceId(id)) sent.add(item.deviceId, id)
        publish()
        if (active(item.deviceId)) scope.launch { fill(item.deviceId) }
    }

    // The assets the guest has not got yet, in the library's order.
    private suspend fun candidates(deviceId: String): List<Asset>? = withContext(Dispatchers.IO) {
        val all = assets()?.filter { isValidSourceId(it.sourceId) } ?: return@withContext null
        val missing = sent.missing(deviceId, all.map { it.sourceId }).toSet()
        val seen = HashSet<String>()
        all.filter { it.sourceId in missing && seen.add(it.sourceId) }
    }

    private suspend fun fill(deviceId: String) = locks.getOrPut(deviceId) { Mutex() }.withLock {
        while (active(deviceId) && !topUp(deviceId)) delay(retryMs)
    }

    /** False when the phone is too full to copy another file. */
    private suspend fun topUp(deviceId: String): Boolean {
        while (active(deviceId)) {
            val waiting = outbox.pending(deviceId).filter { it.sourceId != null }
            if (waiting.size >= FEED_QUEUE_LIMIT) return true
            val asset = synchronized(this) { lists[deviceId]?.removeFirstOrNull() }
            if (asset == null) {
                if (waiting.isEmpty()) finish(deviceId)
                return true
            }
            if (sent.contains(deviceId, asset.sourceId) || waiting.any { it.sourceId == asset.sourceId }) continue
            if (!queue(deviceId, asset)) return false
        }
        return true
    }

    private suspend fun queue(deviceId: String, asset: Asset): Boolean {
        try {
            withContext(Dispatchers.IO) {
                outbox.queueFile(deviceId, asset.name, asset.mime, asset.size, asset.sourceId, asset.modifiedMs) { open(asset) }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: IllegalStateException) {
            synchronized(this) {
                lists[deviceId]?.addFirst(asset)
                low.add(deviceId)
            }
            publish()
            return false
        } catch (e: Exception) {
            // An asset that cannot be read is left out of this run.
            return true
        }
        val wasLow = synchronized(this) { low.remove(deviceId) }
        if (wasLow) publish()
        // The run was stopped while the copy was being made.
        if (!active(deviceId)) outbox.removeGalleryItems(deviceId)
        return true
    }

    private fun finish(deviceId: String) {
        synchronized(this) {
            val run = runs[deviceId] ?: return
            if (run.done) return
            runs = runs + (deviceId to run.copy(done = true))
            lists.remove(deviceId)
            save()
        }
        publish()
    }

    private fun publish() {
        shown.value = synchronized(this) {
            runs.mapValues { (id, run) -> FeedProgress(maxOf(sent.count(id) - run.base, 0), run.total, run.done, id in low) }
        }
    }

    private fun save() {
        runCatching { file.saveJson(FeedFile(runs)) }
    }
}
