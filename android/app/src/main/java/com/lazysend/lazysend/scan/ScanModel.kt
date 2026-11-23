package com.lazysend.lazysend.scan

import android.graphics.Bitmap
import androidx.annotation.StringRes
import com.lazysend.lazysend.R
import java.util.UUID
import kotlin.properties.Delegates
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** A shot or a page waiting for the corner editor: the photo upright, the corners to start from and what the answer is for. */
class CornerRequest(
    val photo: RgbaImage,
    val source: ByteArray,
    val corners: Quad,
    val filter: CaptureFilter,
    /** The page a recut replaces; null for a new shot. */
    val replacing: UUID?,
) {
    val id: UUID = UUID.randomUUID()
}

sealed interface CornerAnswer {
    data class Use(val quad: Quad) : CornerAnswer

    data object Whole : CornerAnswer

    data object Cancel : CornerAnswer
}

/** What the shutter's decision comes to; see [ScanModel.autoShot]. */
enum class AutoShot { Take, Forget, None }

/** What the scan model needs of the camera screen: whether a photo can be taken now, and the photo as a JPEG with its orientation tag. */
interface ScanCamera {
    val ready: Boolean

    /** Null when the photo could not be taken. */
    suspend fun takePhoto(): ByteArray?
}

sealed interface ScanProblem {
    data class Res(@StringRes val id: Int) : ScanProblem

    /** A reason from the send path, already in words. */
    data class Message(val text: String) : ScanProblem
}

/**
 * The scan mode of the camera tab: the live outline of the page, the shutter's decision (automatic or by hand), the pages
 * taken so far and what a page becomes (found, cut out and cleaned up with the filter chosen). The pages are kept in the
 * store until Done sends them, so a scan survives the app being closed by the system; memory holds only the page JPEGs.
 *
 * State is changed on `scope`'s thread (the main thread in the app); the store is only touched on `disk`, one job at a time
 * in the order the work was asked for, so a delete after a save wins. The photo is taken by the [camera] the camera screen
 * sets, and its frames reach the tracker through [feed] (an analyzer to bind to CameraX's ImageAnalysis).
 * `fixedLive` is the demo's: the outline shown instead of the tracker's.
 */
class ScanModel(
    private val scope: CoroutineScope,
    private val store: ScanPageStore?,
    private val finder: CornerModel?,
    val feed: ScanFrameFeed,
    private val sendPages: suspend (List<ScanPage>) -> String,
    private val disk: CoroutineDispatcher,
    private val work: CoroutineDispatcher = Dispatchers.Default,
    private val clock: () -> Long = System::currentTimeMillis,
    private val fixedLive: LiveQuadUpdate? = null,
) {
    private val _pages = MutableStateFlow<List<ScanPage>>(emptyList())
    val pages: StateFlow<List<ScanPage>> = _pages.asStateFlow()

    private val _live = MutableStateFlow<LiveQuadUpdate?>(null)
    val live: StateFlow<LiveQuadUpdate?> = _live.asStateFlow()

    private val _working = MutableStateFlow(false)

    /** A shot is being read, cut out and cleaned up. */
    val working: StateFlow<Boolean> = _working.asStateFlow()

    private val _sending = MutableStateFlow(false)

    /** The pages are being sent: they cannot be cropped or deleted, since they would go anyway. */
    val sending: StateFlow<Boolean> = _sending.asStateFlow()

    private val _shotEditing = MutableStateFlow<CornerRequest?>(null)

    /** The corner editor for a shot the page was not clearly found in. */
    val shotEditing: StateFlow<CornerRequest?> = _shotEditing.asStateFlow()

    private val _pageEditing = MutableStateFlow<CornerRequest?>(null)

    /** The corner editor for a page cut again from the page stack. */
    val pageEditing: StateFlow<CornerRequest?> = _pageEditing.asStateFlow()

    private val _problem = MutableStateFlow<ScanProblem?>(null)
    val problem: StateFlow<ScanProblem?> = _problem.asStateFlow()

    private val _lastName = MutableStateFlow<String?>(null)

    /** The file name of the last scan sent, which is how its row in the timeline is found. */
    val lastName: StateFlow<String?> = _lastName.asStateFlow()

    /** A page is not deleted while another is being cut again, since the cut would bring it back, nor while the pages are being sent. */
    val busy: StateFlow<Boolean> = combine(_working, _pageEditing, _sending) { working, editing, sending ->
        working || editing != null || sending
    }.stateIn(scope, SharingStarted.Eagerly, false)

    val canCrop: StateFlow<Boolean> = combine(_working, _sending) { working, sending -> !working && !sending }
        .stateIn(scope, SharingStarted.Eagerly, true)

    /** Set by the camera screen while it shows the camera. */
    var camera: ScanCamera? = null

    private val tracker = LiveQuadTracker()
    private var attached = false
    private var flowing = false

    /** Auto waits this long after the camera starts, so opening the app over a page does not take it at once. */
    private var graceEnds = 0L
    private val thumbnails = HashMap<UUID, Bitmap>()

    /** The pages the store has, or will have once the work queued for it is done. */
    private val stored = HashSet<UUID>()

    /** The photos of pages that could not be saved, so they can still be cut again this session. */
    private val kept = HashMap<UUID, ByteArray>()
    private var loading = false
    private val loaded = CompletableDeferred<Unit>()
    private val removedWhileLoading = HashSet<UUID>()
    private var orderChangedWhileLoading = false

    /** Set by the owner of the settings: the filter new pages get, whether a page is taken without being asked... */
    var filter = CaptureFilter.Enhanced

    /** ...and whether there is a device for the scan to go to, which a page is not taken without. */
    var hasTarget: Boolean by Delegates.observable(false) { _, old, new -> if (new && !old) tracker.reset() }

    var auto: Boolean by Delegates.observable(true) { _, old, new -> if (new && !old) tracker.rearm() }

    init {
        if (store == null) {
            loaded.complete(Unit)
        } else {
            loading = true
            // Dispatched at once, so nothing asked of the store later gets in front of the read.
            scope.launch(disk) {
                val pages = store.load()
                scope.launch {
                    finishLoading(pages)
                    loaded.complete(Unit)
                }
            }
        }
    }

    /** The pages the store held come first; a page taken before they were read goes after them. */
    private fun finishLoading(fromStore: List<ScanPage>) {
        loading = false
        val have = _pages.value.map { it.id }.toSet()
        val fromDisk = fromStore.filter { it.id !in removedWhileLoading && it.id !in have }
        stored += fromDisk.map { it.id }
        _pages.value = fromDisk + _pages.value
        removedWhileLoading.clear()
        if (orderChangedWhileLoading) saveOrder()
        orderChangedWhileLoading = false
    }

    private fun persist(job: (ScanPageStore) -> Unit) {
        val store = store ?: return
        scope.launch(disk) { job(store) }
    }

    /** Returns once the pages are read and everything asked of the store so far is written. */
    suspend fun waitForDisk() {
        loaded.await()
        withContext(disk) {}
    }

    /**
     * Scan mode is in front of a running camera: [attached] says the analysis is bound to the camera, [covered] that a sheet or the
     * corner editor is over it, which only stops the frames, since unbinding and binding again would restart the camera.
     */
    fun setLive(attached: Boolean, covered: Boolean) {
        if (attached != this.attached) {
            this.attached = attached
            if (attached) {
                graceEnds = clock() + CaptureStability.AUTO_GRACE_MS.toLong()
            } else {
                feed.stop()
                tracker.pause()
                flowing = false
                _live.value = null
                return
            }
        }
        val flow = flows(this.attached, covered)
        if (flow == flowing) return
        flowing = flow
        when {
            fixedLive != null -> _live.value = if (flow) fixedLive else null
            flow -> feed.start { frame ->
                val update = tracker.process(frame) ?: return@start
                scope.launch { apply(update) }
            }
            else -> {
                feed.stop()
                tracker.pause()
                _live.value = null
            }
        }
    }

    internal fun apply(update: LiveQuadUpdate) {
        if (!flowing) return
        _live.value = update
        when (autoShot(update, auto, canShoot, clock() < graceEnds)) {
            AutoShot.Take -> shoot()
            AutoShot.Forget -> tracker.reset()
            AutoShot.None -> {}
        }
    }

    /** A photo can be taken: a camera that runs, no shot being worked on and no editor open. */
    val canShoot: Boolean
        get() = camera?.ready == true && hasTarget && !_working.value && _shotEditing.value == null && _pageEditing.value == null

    fun shoot() {
        val camera = camera ?: return
        if (!canShoot) return
        _working.value = true
        _problem.value = null
        tracker.markCaptured()
        val filter = filter
        scope.launch {
            val data = try {
                camera.takePhoto()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            }
            if (data == null) {
                _working.value = false
                _problem.value = ScanProblem.Res(R.string.camera_photo_failed)
                tracker.reset()
                return@launch
            }
            val outcome = withContext(work) { read(data, filter, finder) }
            _working.value = false
            when (outcome) {
                is Outcome.Page -> add(outcome.page, data)
                is Outcome.Corners -> _shotEditing.value = CornerRequest(outcome.photo, data, outcome.corners, filter, null)
                Outcome.Failed -> {
                    _problem.value = ScanProblem.Res(R.string.scan_photo_unreadable)
                    tracker.reset()
                }
            }
        }
    }

    private sealed interface Outcome {
        class Page(val page: ScanPage) : Outcome

        class Corners(val photo: RgbaImage, val corners: Quad) : Outcome

        data object Failed : Outcome
    }

    /** A shot read, its page looked for and, when it is found clearly, cut out; else the photo and the corners to start from. */
    private fun read(data: ByteArray, filter: CaptureFilter, finder: CornerModel?): Outcome {
        val photo = PhotoReader.decode(data) ?: return Outcome.Failed
        val found = PageFinder.find(photo, finder)
        if (found.clear) {
            PagePipeline.page(photo, found.corners, filter)?.let { return Outcome.Page(it) }
        }
        return Outcome.Corners(photo, found.corners)
    }

    /**
     * What the editor was asked for, answered: the page is cut along the corners as placed, or is the whole photo, or the
     * shot is dropped (a retake) and a recut leaves the page as it was.
     */
    fun answer(request: CornerRequest, answer: CornerAnswer) {
        if (_shotEditing.value?.id == request.id) _shotEditing.value = null
        if (_pageEditing.value?.id == request.id) _pageEditing.value = null
        val corners = when (answer) {
            // The page still in view may be taken again.
            CornerAnswer.Cancel -> {
                tracker.reset()
                return
            }
            is CornerAnswer.Use -> answer.quad
            CornerAnswer.Whole -> null
        }
        _working.value = true
        scope.launch {
            val page = withContext(work) {
                val id = request.replacing ?: UUID.randomUUID()
                if (corners == null) {
                    PagePipeline.wholePage(request.photo, request.filter, id)
                } else {
                    PagePipeline.page(request.photo, corners, request.filter, id)
                }
            }
            _working.value = false
            if (page == null) {
                _problem.value = ScanProblem.Res(R.string.scan_page_not_cut)
                return@launch
            }
            // The page it replaces went while it was being cut: it must not come back.
            val replacing = request.replacing
            if (replacing != null && _pages.value.none { it.id == replacing }) return@launch
            add(page, request.source)
        }
    }

    /** The page added at the end, or in place of the page it was cut again from, with the photo it was cut from. */
    fun add(page: ScanPage, source: ByteArray) {
        // A page the store has keeps its photo, so a cut again writes only the page.
        val photo = if (page.id in stored) null else source
        stored += page.id
        val id = page.id
        persist { store ->
            try {
                store.save(page, photo)
                if (photo != null) scope.launch { kept.remove(id) }
            } catch (e: Exception) {
                scope.launch { saveFailed(id, source) }
            }
        }
        thumbnails.remove(id)
        val index = _pages.value.indexOfFirst { it.id == id }
        if (index >= 0) {
            _pages.value = _pages.value.toMutableList().also { it[index] = page }
        } else {
            _pages.value += page
            _lastName.value = null
        }
    }

    private fun saveFailed(id: UUID, source: ByteArray) {
        if (_pages.value.none { it.id == id }) return
        stored.remove(id)
        kept[id] = source
        _problem.value = ScanProblem.Res(R.string.scan_page_not_saved)
    }

    /** The page cut again: its photo is read and the editor opens at the corners it was cut along. */
    fun recut(page: ScanPage) {
        if (_working.value) return
        _working.value = true
        val id = page.id
        val memory = kept[id]
        scope.launch {
            // Read on the store's queue, after whatever is still being written for the page.
            val data = memory ?: store?.let { withContext(disk) { it.source(id) } }
            val photo = data?.let { withContext(work) { PhotoReader.decode(it) } }
            _working.value = false
            if (data == null || photo == null) {
                _problem.value = ScanProblem.Res(R.string.scan_photo_unreadable)
                return@launch
            }
            val corners = PageFinder.clamped(page.corners, photo.width, photo.height)
            _pageEditing.value = CornerRequest(photo, data, corners, page.filter, id)
        }
    }

    fun delete(id: UUID) = drop(listOf(id))

    private fun drop(ids: List<UUID>) {
        val gone = ids.toSet()
        _pages.value = _pages.value.filter { it.id !in gone }
        for (id in ids) {
            thumbnails.remove(id)
            kept.remove(id)
            stored.remove(id)
        }
        if (loading) removedWhileLoading += gone
        persist { store -> ids.forEach(store::remove) }
    }

    /** The page at index [from] moved to index [to] of the list it ends up in, as a drag does. */
    fun move(from: Int, to: Int) {
        val list = _pages.value.toMutableList()
        if (from !in list.indices || to !in list.indices) return
        list.add(to, list.removeAt(from))
        _pages.value = list
        saveOrder()
    }

    /** [id] one place earlier ([step] -1) or later (1). */
    fun shift(id: UUID, step: Int) {
        val list = _pages.value.toMutableList()
        val index = list.indexOfFirst { it.id == id }
        val other = index + step
        if (index < 0 || other !in list.indices) return
        list[index] = list[other].also { list[other] = list[index] }
        _pages.value = list
        saveOrder()
    }

    private fun saveOrder() {
        // The stored list is not read yet; it is written when it is.
        if (loading) {
            orderChangedWhileLoading = true
            return
        }
        val ids = _pages.value.map { it.id }
        persist { runCatching { it.setOrder(ids) } }
    }

    /** Sends the pages as they are now; the sender says what the file is called. */
    fun done() {
        val batch = _pages.value
        if (batch.isEmpty() || _sending.value || _working.value) return
        _sending.value = true
        _problem.value = null
        scope.launch {
            try {
                sent(sendPages(batch), batch.map { it.id })
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val reason = e.message
                _problem.value = if (reason.isNullOrBlank()) ScanProblem.Res(R.string.scan_not_sent) else ScanProblem.Message(reason)
            } finally {
                _sending.value = false
            }
        }
    }

    fun clearProblem() {
        _problem.value = null
    }

    /** The pages [ids] went in one file named [name]; pages taken while it was being sent stay. */
    fun sent(name: String, ids: List<UUID>) {
        _lastName.value = name
        drop(ids)
        tracker.reset()
    }

    /** A small picture of the page, kept until the page changes. */
    fun thumbnail(page: ScanPage): Bitmap? {
        thumbnails[page.id]?.let { return it }
        val small = page.jpeg.toThumbnail(THUMBNAIL_SIDE) ?: return null
        thumbnails[page.id] = small
        return small
    }

    companion object {
        private const val THUMBNAIL_SIDE = 360

        /** Frames are handed to the tracker while the analysis is bound and a sheet or the corner editor is not covering it. */
        fun flows(attached: Boolean, covered: Boolean) = attached && !covered

        /**
         * What the shutter's decision comes to: the photo is taken; or, when a photo cannot be taken now (one is being made, no
         * device, Auto's wait after the camera started) the tracker forgets the decision, since it would otherwise keep the page
         * as taken and never decide again; or nothing, with Auto off, where the decision stands for when it is turned on.
         */
        fun autoShot(update: LiveQuadUpdate, auto: Boolean, canShoot: Boolean, inGrace: Boolean): AutoShot {
            if (!update.shouldCapture || !auto) return AutoShot.None
            return if (canShoot && !inGrace) AutoShot.Take else AutoShot.Forget
        }
    }
}
