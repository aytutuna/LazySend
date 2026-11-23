package com.lazysend.lazysend.ui

import android.app.Application
import android.content.ClipboardManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.lazysend.lazysend.BuildConfig
import com.lazysend.lazysend.LazySendApp
import com.lazysend.lazysend.R
import com.lazysend.lazysend.data.Direction
import com.lazysend.lazysend.data.Pc
import com.lazysend.lazysend.host.Approval
import com.lazysend.lazysend.host.Guest
import com.lazysend.lazysend.link.LinkException
import com.lazysend.lazysend.link.PairingCode
import com.lazysend.lazysend.link.PairingCodeException
import com.lazysend.lazysend.transfer.Pasted
import com.lazysend.lazysend.transfer.PhotoFormat
import com.lazysend.lazysend.transfer.convertPhoto
import com.lazysend.lazysend.transfer.convertedName
import com.lazysend.lazysend.transfer.SendService
import com.lazysend.lazysend.transfer.clipboardName
import com.lazysend.lazysend.scan.CaptureFilter
import com.lazysend.lazysend.scan.CornerModels
import com.lazysend.lazysend.scan.ScanDemo
import com.lazysend.lazysend.scan.ScanFrameFeed
import com.lazysend.lazysend.scan.ScanModel
import com.lazysend.lazysend.scan.ScanPage
import com.lazysend.lazysend.scan.ScanPageStore
import com.lazysend.lazysend.scan.ScanPdf
import com.lazysend.lazysend.transfer.pasted
import com.lazysend.lazysend.transfer.photoName
import com.lazysend.lazysend.transfer.scanName
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.withContext
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

private const val DAY = 24 * 60 * 60 * 1000L

/** What the clipboard may hold to be sent, since it is copied to the cache first. */
private const val PASTE_LIMIT = 2L * 1024 * 1024 * 1024

/** The camera's last photo, by file name, with a small picture of it once that is ready. */
class Shot(val name: String, val thumbnail: Bitmap?)

/** Rows of the devices that are guests of this phone have this in front of their id, so a device that is both has two rows. */
private const val GUEST = "guest:"

class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val graph = (app as LazySendApp).graph
    private val selected = MutableStateFlow(graph.settings.target)
    private val photoAccess = MutableStateFlow(PhotoAccess.None)
    private var pairJob: Job? = null

    val pair = MutableStateFlow<PairUi>(PairUi.Scanning)

    /** The last photo the camera took, which the camera tab shows while it is sent. */
    val shot = MutableStateFlow<Shot?>(null)
    val cameraProblem = MutableStateFlow<String?>(null)
    val clipProblem = MutableStateFlow<String?>(null)
    val saveCameraPhotos: StateFlow<Boolean> get() = graph.settings.saveCameraPhotos

    /** The scan mode of the camera tab; it lives as long as the app does, so a scan in progress survives leaving the camera. */
    val scan: ScanModel = createScan()

    val state: StateFlow<MainState> = combine(
        combine(graph.pcs.pcs, graph.host.core.guests.guests, graph.host.core.feed.progress) { pcs, guests, feeds -> Triple(pcs, guests, feeds) },
        graph.timeline.entries, graph.connector.current, selected, combine(photoAccess, graph.settings.photoFormat) { access, format -> access to format },
    ) { (pcs, guests, feeds), entries, links, pick, (access, format) ->
        val rows = pcs.map { PcRow(it.id, it.name, links[it.id]?.label) } + guests.map { PcRow(GUEST + it.id, it.name, null, guest = true) }
        val chosen = pick?.takeIf { id -> rows.any { it.id == id } } ?: rows.firstOrNull()?.id
        MainState(
            pcs = rows,
            selected = chosen,
            entries = entries,
            photoAccess = access,
            format = format,
            feed = chosen?.takeIf { it.startsWith(GUEST) }?.let { feeds[it.removePrefix(GUEST)] },
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), MainState(emptyList(), null, emptyList()))

    val receive: StateFlow<ReceiveUi> = combine(graph.host.state, graph.host.core.approval, graph.host.core.guests.guests) { host, approval, guests ->
        ReceiveUi(host, approval, guests.map { it.name })
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ReceiveUi())

    /** True while this phone hosts with a guest paired: the screen that sees it asks for the service that keeps it going. */
    val keepHosting: StateFlow<Boolean> get() = graph.host.keepAlive

    private fun createScan(): ScanModel {
        val app = getApplication<Application>()
        val demo = BuildConfig.DEBUG && ScanDemo.on
        val store = if (demo) {
            ScanPageStore(File(app.cacheDir, "demo-scan-pages")).also { it.removeAll() }
        } else {
            ScanPageStore(File(app.noBackupFilesDir, "scan-pages"))
        }
        val finder = if (demo) ScanDemo.finder() else CornerModels.fromAssets(app)
        val power = app.getSystemService(PowerManager::class.java)
        val warm = { Build.VERSION.SDK_INT >= 29 && power.currentThermalStatus >= PowerManager.THERMAL_STATUS_MODERATE }
        val model = ScanModel(
            viewModelScope, store, finder, ScanFrameFeed(finder, warm), ::sendScan,
            disk = Dispatchers.IO.limitedParallelism(1), fixedLive = if (demo) ScanDemo.update else null,
        )
        if (demo) model.camera = ScanDemo.camera
        return model
    }

    override fun onCleared() {
        scan.feed.close()
    }

    fun select(id: String) {
        selected.value = id
        graph.settings.target = id
    }

    fun saveCameraPhotos(on: Boolean) = graph.settings.saveCameraPhotos(on)

    fun photoFormat(format: PhotoFormat) = graph.settings.photoFormat(format)

    val scanFilter: StateFlow<CaptureFilter> get() = graph.settings.scanFilter
    val scanAuto: StateFlow<Boolean> get() = graph.settings.scanAuto

    fun setScanFilter(filter: CaptureFilter) = graph.settings.scanFilter(filter)

    fun setScanAuto(on: Boolean) = graph.settings.scanAuto(on)

    /**
     * Sends what was picked in the Files tab at once to the selected device. Photos are converted to the chosen format as each one is
     * sent, by the sending service, so leaving the screen does not lose the pick; files are sent exactly as they are.
     */
    fun sendPicked(uris: List<Uri>, photos: Boolean) {
        val context = getApplication<Application>()
        val format = graph.settings.photoFormat.value.takeIf { photos }
        val guest = selectedGuest()
        val pc = selectedPc()
        when {
            guest != null -> SendService.queueFiles(context, guest.id, uris, format = format)
            pc != null -> SendService.sendFiles(context, pc.id, uris, format = format)
        }
    }

    /** Where the next camera photo goes, named by the time and by milliseconds too when the plain name is taken. */
    suspend fun newPhotoFile(): File = withContext(Dispatchers.IO) {
        val dir = cacheFolder("camera")
        val sent = graph.timeline.entries.value
        // The shot is captured as a JPEG and may be converted after, so both names must be free.
        fun taken(name: String) = File(dir, name).exists() || sent.any { it.direction == Direction.Sent && it.title == name }
        File(dir, photoName(System.currentTimeMillis()) { name -> taken(name) || taken(convertedName(name, PhotoFormat.Png)) })
    }

    /** A photo the camera saved: it goes at once to the selected device, to be put on its clipboard. */
    fun photoTaken(file: File) {
        val at = System.currentTimeMillis()
        val format = graph.settings.photoFormat.value
        viewModelScope.launch(Dispatchers.IO) {
            // The camera's JPEG is already upright and tagged; only a PNG is made from it, with the turn applied to the pixels.
            val ready = if (format == PhotoFormat.Png) {
                convertPhoto(getApplication(), Uri.fromFile(file), file.name, "image/jpeg", format, file.parentFile!!)?.also { file.delete() } ?: file
            } else {
                file
            }
            shot.value = Shot(ready.name, null)
            // Saved first, so a send that fails never loses the photo.
            if (graph.settings.saveCameraPhotos.value) saveToGallery(ready)
            if (!sendClipped(ready, cameraProblem, at)) return@launch
            shot.value = Shot(ready.name, jpegThumbnail(ready))
        }
    }

    fun cameraFailed(message: String) {
        cameraProblem.value = message
    }

    fun clearCameraProblem() {
        cameraProblem.value = null
    }

    /** Sends what the clipboard holds, read now while the app is in front, to the selected device's clipboard. */
    fun paste() {
        val context = getApplication<Application>()
        val clip = context.getSystemService(ClipboardManager::class.java).primaryClip?.takeIf { it.itemCount > 0 }
        val item = clip?.getItemAt(0)
        val at = System.currentTimeMillis()
        viewModelScope.launch(Dispatchers.IO) {
            val uri = item?.uri
            val mime = uri?.let { runCatching { context.contentResolver.getType(it) }.getOrNull() ?: clip.description.getMimeType(0) }
            when (val found = pasted(item?.text, uri?.toString(), mime)) {
                null -> clipProblem.value = context.getString(R.string.nothing_to_send)
                is Pasted.Note -> sendClipText(found.text, at)
                is Pasted.Attachment -> {
                    val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(found.mime) ?: "bin"
                    val file = File(cacheFolder("clipboard"), clipboardName(System.currentTimeMillis(), extension))
                    try {
                        context.contentResolver.openInputStream(Uri.parse(found.uri))!!.use { input -> file.outputStream().use { copyLimited(input, it) } }
                    } catch (e: TooBig) {
                        file.delete()
                        clipProblem.value = context.getString(R.string.paste_too_big)
                        return@launch
                    } catch (e: Exception) {
                        file.delete()
                        clipProblem.value = context.getString(R.string.paste_read_failed)
                        return@launch
                    }
                    if (sendClipped(file, clipProblem, at)) clipProblem.value = null
                }
            }
        }
    }

    /** Sends text to the selected device's clipboard; a lone address goes as a link. */
    fun sendClipText(text: String, at: Long = System.currentTimeMillis()) {
        val context = getApplication<Application>()
        val guest = selectedGuest()
        val pc = selectedPc()
        when {
            guest != null -> SendService.queueText(context, guest.id, text, clip = true)
            pc != null -> SendService.sendText(context, pc.id, text, clip = true, at = at)
            else -> {
                clipProblem.value = context.getString(R.string.target_gone)
                return
            }
        }
        clipProblem.value = null
    }

    private class TooBig : IOException()

    private fun copyLimited(input: InputStream, out: OutputStream) {
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val n = input.read(buffer)
            if (n < 0) return
            total += n
            if (total > PASTE_LIMIT) throw TooBig()
            out.write(buffer, 0, n)
        }
    }

    private fun cacheFolder(name: String): File {
        val dir = File(getApplication<Application>().cacheDir, name).apply { mkdirs() }
        dir.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > DAY }?.forEach { it.deleteRecursively() }
        return dir
    }

    private fun sendClipped(file: File, problem: MutableStateFlow<String?>, at: Long): Boolean {
        try {
            handOver(file, clip = true, at)
        } catch (e: Exception) {
            problem.value = e.message ?: getApplication<Application>().getString(R.string.target_gone)
            return false
        }
        return true
    }

    // The file goes through the provider so the sending service reads its name and size like any picked file.
    private fun handOver(file: File, clip: Boolean, at: Long) {
        val context = getApplication<Application>()
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        val guest = selectedGuest()
        val pc = selectedPc()
        when {
            guest != null -> SendService.queueFiles(context, guest.id, listOf(uri), clip = clip)
            pc != null -> SendService.sendFiles(context, pc.id, listOf(uri), clip = clip, at = at)
            else -> throw IOException(context.getString(R.string.target_gone))
        }
    }

    /**
     * Sends a scan to the selected device as one file named by its time and returns the name: a page as the JPEG it is, to be put on
     * the clipboard there like a camera photo, two or more as one PDF. Scans are not saved to the gallery. Throws when the file
     * cannot be written or the device is gone.
     */
    private suspend fun sendScan(pages: List<ScanPage>): String = withContext(Dispatchers.IO) {
        val at = System.currentTimeMillis()
        val single = pages.size == 1
        val bytes = if (single) pages[0].jpeg else withContext(Dispatchers.Default) { ScanPdf.make(pages) }
        val dir = cacheFolder("scan")
        val sent = graph.timeline.entries.value
        val name = scanName(at, if (single) "jpg" else "pdf") { name ->
            File(dir, name).exists() || sent.any { it.direction == Direction.Sent && it.title == name }
        }
        val file = File(dir, name)
        try {
            file.writeBytes(bytes)
            handOver(file, clip = single, at)
        } catch (e: Exception) {
            file.delete()
            throw e
        }
        name
    }

    private fun saveToGallery(file: File) {
        try {
            val part = graph.files.create(file.name, if (file.extension == "png") "image/png" else "image/jpeg")
            graph.files.append(part).use { out -> file.inputStream().use { it.copyTo(out) } }
            graph.files.finish(part, file.lastModified())
        } catch (e: Exception) {
            cameraProblem.value = getApplication<Application>().getString(R.string.camera_save_failed)
        }
    }

    fun photoAccess(access: PhotoAccess) {
        photoAccess.value = access
    }

    fun selectedPc(): Pc? = state.value.selected?.takeIf { !it.startsWith(GUEST) }?.let(graph.pcs::get)

    fun selectedGuest(): Guest? = state.value.selected?.takeIf { it.startsWith(GUEST) }?.let { graph.host.core.guests.get(it.removePrefix(GUEST)) }

    /** Sends the whole library to the selected guest of this phone, a few files at a time as it picks them up. */
    fun startFeed() {
        val guest = selectedGuest() ?: return
        graph.host.start()
        graph.host.core.feed.start(guest.id)
    }

    fun stopFeed() {
        selectedGuest()?.let { graph.host.core.feed.stop(it.id) }
    }

    fun openReceive() = graph.host.open()

    fun pauseReceive() = graph.host.pause()

    /** The app is in front: hosting that was wanted and ended without the person stopping it starts again. */
    fun resumeHosting() {
        graph.notifications.clearPaused()
        graph.host.resumeIfWanted()
        graph.host.core.feed.resume()
    }

    /** The photo permission came back: a feed that was paused for lack of it carries on. */
    fun resumeFeeds() {
        graph.host.core.feed.resume()
    }

    fun leaveReceive() = graph.host.leave()

    fun stopReceiving() = graph.host.stop()

    fun newCode() = graph.host.newCode()

    fun answer(approval: Approval, allow: Boolean) = approval.respond(allow)

    /** Asks every paired PC for what it has queued, for as long as the caller stays active. */
    suspend fun watch() = withContext(Dispatchers.IO) {
        graph.pcs.pcs.map { list -> list.map { it.id } }.distinctUntilChanged().collectLatest { ids ->
            coroutineScope {
                ids.forEach { id -> graph.pcs.get(id)?.let { launch { graph.receiver.watch(it) } } }
            }
        }
    }

    fun startPairing() {
        pairJob?.cancel()
        pair.value = PairUi.Scanning
    }

    /** Pairs from the QR code's text or pasted pairing text; [extraAddress] is only used by debug builds. */
    fun pair(text: String, extraAddress: String?) {
        if (pairJob?.isActive == true || pair.value is PairUi.Paired) return
        val context = getApplication<Application>()
        pairJob = viewModelScope.launch(Dispatchers.IO) {
            val code = try {
                PairingCode.parse(text)
            } catch (e: PairingCodeException) {
                pair.value = PairUi.Failed(e.message.orEmpty())
                return@launch
            }
            pair.value = PairUi.Waiting(code.checkCode)
            val addresses = (code.addresses + listOfNotNull(extraAddress)).distinct()
            val reached = graph.connector.reachForPairing(addresses, code.port, code.pin)
            if (reached == null) {
                pair.value = PairUi.Failed(context.getString(R.string.pair_unreachable))
                return@launch
            }
            try {
                val reply = reached.client.pair(code.token, graph.pcs.phoneId, Build.MODEL, BuildConfig.VERSION_NAME)
                graph.pcs.put(Pc(code.desktopId, reply.desktopName, code.fingerprint, addresses, code.port, reply.deviceSecret, reached.host))
                selected.value = code.desktopId
                pair.value = PairUi.Paired(reply.desktopName)
            } catch (e: LinkException) {
                pair.value = PairUi.Failed(e.message.orEmpty())
            } catch (e: IOException) {
                pair.value = PairUi.Failed(context.getString(R.string.pair_unreachable))
            }
        }
    }

    /** Forgets the PC here and, when it can be reached, there too; a guest of this phone is forgotten here and finds out when it asks. */
    fun remove(id: String) {
        if (id.startsWith(GUEST)) {
            viewModelScope.launch(Dispatchers.IO) { graph.host.removeGuest(id.removePrefix(GUEST)) }
            return
        }
        val pc = graph.pcs.get(id) ?: return
        graph.pcs.remove(id)
        viewModelScope.launch(Dispatchers.IO) {
            graph.receiver.forget(id)
            val reached = graph.connector.connect(pc, search = false) as? com.lazysend.lazysend.transfer.Reach.Reached
            try {
                reached?.client?.forgetSelf()
            } catch (e: IOException) {
                // It will notice when this phone asks again and is turned away.
            } catch (e: LinkException) {
            }
            graph.connector.lost(id)
        }
    }
}
