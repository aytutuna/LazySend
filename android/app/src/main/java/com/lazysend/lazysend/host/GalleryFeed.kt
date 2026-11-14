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

/** Why a running feed is not queuing anything for now. */
enum class FeedWait { Storage, Outbox, Photos, NotHosting }

/** [failed] counts assets that could not be read, also after a second try. */
data class FeedProgress(val sent: Int, val total: Int, val done: Boolean, val failed: Int = 0, val wait: FeedWait? = null)

@Serializable
private data class FeedRun(val total: Int, val base: Int, val done: Boolean = false, val failed: Int = 0)

@Serializable
private data class FeedFile(val runs: Map<String, FeedRun> = emptyMap())

const val FEED_QUEUE_LIMIT = 20

/** About this many bytes of copies wait at a time; one item always may, however large. */
const val FEED_QUEUE_BYTES = 1024L * 1024 * 1024

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
    private val queueBytes: Long = FEED_QUEUE_BYTES,
    private val hosting: () -> Boolean = { true },
) {
    private var runs = loadJson(file) { FeedFile() }.runs
    // What is left to queue for each running guest, in the library's order.
    private val lists = HashMap<String, ArrayDeque<Asset>>()
    // Assets that failed once, tried again when the list is used up, and the ids already tried twice.
    private val later = HashMap<String, ArrayList<Asset>>()
    private val retried = HashMap<String, HashSet<String>>()
    private val waits = HashMap<String, FeedWait>()
    // Guests whose run is being set up: the library is read before the run exists.
    private val starting = HashSet<String>()
    // The library could not be read the last time it was needed (permission taken away).
    private var noPhotos = false
    private val locks = ConcurrentHashMap<String, Mutex>()
    private val shown = MutableStateFlow<Map<String, FeedProgress>>(emptyMap())

    val progress: StateFlow<Map<String, FeedProgress>> get() = shown

    init {
        outbox.onAcknowledged = ::acknowledged
        publish()
    }

    /** The host started or stopped: the progress line follows, and nothing is copied while it is stopped. */
    fun refresh() = publish()

    @Synchronized
    fun running(): Set<String> = runs.filterValues { !it.done }.keys

    @Synchronized
    private fun active(deviceId: String) = runs[deviceId]?.done == false

    /** Starts a run for the guest unless one is going; does nothing while the library cannot be read. */
    fun start(deviceId: String): Job = scope.launch {
        if (!synchronized(this@GalleryFeed) { runs[deviceId]?.done != false && starting.add(deviceId) }) return@launch
        val todo = candidates(deviceId)
        synchronized(this@GalleryFeed) {
            // Removing the guest while the library was being read cancels the start.
            if (!starting.remove(deviceId) || todo == null) return@launch
            runs = runs + (deviceId to FeedRun(todo.size, sent.count(deviceId)))
            lists[deviceId] = ArrayDeque(todo)
            save()
        }
        publish()
        fill(deviceId)
    }

    /** Carries on the runs that were going when the app was closed. */
    fun resume(): Job = scope.launch {
        publish()
        for (deviceId in running()) {
            launch {
                if (synchronized(this@GalleryFeed) { lists[deviceId] } == null) {
                    val todo = candidates(deviceId)
                    val changed = synchronized(this@GalleryFeed) { (noPhotos != (todo == null)).also { noPhotos = todo == null } }
                    if (changed) publish()
                    if (todo == null) return@launch
                    synchronized(this@GalleryFeed) { if (active(deviceId)) lists[deviceId] = ArrayDeque(todo) }
                }
                fill(deviceId)
            }
        }
    }

    /** Ends the run and takes back what was queued and not yet acknowledged, with its copies. */
    fun stop(deviceId: String) {
        synchronized(this) {
            starting.remove(deviceId)
            runs = runs - deviceId
            clearState(deviceId)
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
        synchronized(this) { (runs.keys + starting).filter { it !in paired } }.forEach(::forget)
    }

    private fun acknowledged(item: OutboxItem) {
        val id = item.sourceId
        if (id != null && isValidSourceId(id)) sent.add(item.deviceId, id)
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
            // Nothing is copied while no guest can come and get it; the host starting again resumes the feed.
            if (!hosting()) return true
            val waiting = outbox.pending(deviceId).filter { it.sourceId != null }
            if (waiting.size >= FEED_QUEUE_LIMIT) return true
            val asset = synchronized(this) { lists[deviceId]?.firstOrNull() }
            if (asset == null) {
                val again = synchronized(this) {
                    later.remove(deviceId)?.takeIf { it.isNotEmpty() }?.also { lists[deviceId] = ArrayDeque(it) }
                }
                if (again != null) continue
                if (waiting.isEmpty()) finish(deviceId)
                return true
            }
            if (sent.contains(deviceId, asset.sourceId) || waiting.any { it.sourceId == asset.sourceId }) {
                synchronized(this) { lists[deviceId]?.removeFirstOrNull() }
                continue
            }
            if (outbox.pending(deviceId).size >= MAX_QUEUED) {
                setWait(deviceId, FeedWait.Outbox)
                return true
            }
            if (waiting.isNotEmpty() && waiting.sumOf { it.size ?: 0L } + asset.size > queueBytes) return true
            synchronized(this) { lists[deviceId]?.removeFirstOrNull() }
            if (!queue(deviceId, asset)) return false
        }
        return true
    }

    // An asset that cannot be read is tried once more after the others, then counted as not sent.
    private fun failed(deviceId: String, asset: Asset) {
        synchronized(this) {
            val run = runs[deviceId]?.takeIf { !it.done } ?: return
            if (retried.getOrPut(deviceId) { HashSet() }.add(asset.sourceId)) {
                later.getOrPut(deviceId) { ArrayList() }.add(asset)
            } else {
                runs = runs + (deviceId to run.copy(failed = run.failed + 1))
                save()
            }
        }
        publish()
    }

    private fun setWait(deviceId: String, wait: FeedWait?) {
        val changed = synchronized(this) { if (wait == null) waits.remove(deviceId) != null else waits.put(deviceId, wait) != wait }
        if (changed) publish()
    }

    private fun clearState(deviceId: String) {
        lists.remove(deviceId)
        later.remove(deviceId)
        retried.remove(deviceId)
        waits.remove(deviceId)
    }

    private suspend fun queue(deviceId: String, asset: Asset): Boolean {
        try {
            withContext(Dispatchers.IO) {
                outbox.queueFile(deviceId, asset.name, asset.mime, asset.size, asset.sourceId, asset.modifiedMs) { open(asset) }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: OutboxFullException) {
            // Someone else filled the outbox meanwhile: the asset waits for the next acknowledgement.
            synchronized(this) { lists[deviceId]?.addFirst(asset) }
            setWait(deviceId, FeedWait.Outbox)
            return true
        } catch (e: LowStorageException) {
            synchronized(this) { lists[deviceId]?.addFirst(asset) }
            setWait(deviceId, FeedWait.Storage)
            return false
        } catch (e: Exception) {
            failed(deviceId, asset)
            return true
        }
        setWait(deviceId, null)
        // The run was stopped while the copy was being made.
        if (!active(deviceId)) outbox.removeGalleryItems(deviceId)
        return true
    }

    private fun finish(deviceId: String) {
        synchronized(this) {
            val run = runs[deviceId] ?: return
            if (run.done) return
            runs = runs + (deviceId to run.copy(done = true))
            clearState(deviceId)
            save()
        }
        publish()
    }

    private fun publish() {
        shown.value = synchronized(this) {
            runs.mapValues { (id, run) ->
                val count = maxOf(sent.count(id) - run.base, 0)
                FeedProgress(count, maxOf(run.total, count + run.failed), run.done, run.failed, if (run.done) null else if (noPhotos) FeedWait.Photos else if (!hosting()) FeedWait.NotHosting else waits[id])
            }
        }
    }

    private fun save() {
        runCatching { file.saveJson(FeedFile(runs)) }
    }
}
