package com.lazysend.lazysend.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.display.DisplayManager
import android.net.Uri
import android.provider.Settings
import android.view.OrientationEventListener
import android.view.Surface
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.AspectRatio
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.ZoomState
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.Observer
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.lazysend.lazysend.BuildConfig
import com.lazysend.lazysend.R
import com.lazysend.lazysend.data.TimelineEntry
import com.lazysend.lazysend.scan.CaptureFilter
import com.lazysend.lazysend.scan.CornerAnswer
import com.lazysend.lazysend.scan.ScanCamera
import com.lazysend.lazysend.scan.ScanDemo
import com.lazysend.lazysend.scan.ScanModel
import com.lazysend.lazysend.transfer.PhotoFormat
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * The camera tab: a live viewfinder, and every photo goes to the chosen device's clipboard as soon as it is taken. In scan mode
 * ([scanning]) the shutter takes pages instead, which go as one file when the scan is done. The camera is held only while this
 * screen is composed and the activity is resumed.
 */
@Composable
fun CameraScreen(
    canAsk: Boolean,
    asked: Boolean,
    onAsked: () -> Unit,
    targets: List<PcRow>,
    selected: String?,
    entries: List<TimelineEntry>,
    shot: Shot?,
    problem: String?,
    onSelect: (String) -> Unit,
    onPair: () -> Unit,
    onHistory: () -> Unit,
    newFile: suspend () -> File,
    onTaken: (File) -> Unit,
    onFailed: (String) -> Unit,
    onClearProblem: () -> Unit,
    format: PhotoFormat,
    onFormat: (PhotoFormat) -> Unit,
    scan: ScanModel,
    scanning: Boolean,
    onScanning: (Boolean) -> Unit,
    scanFilter: CaptureFilter,
    onScanFilter: (CaptureFilter) -> Unit,
    scanAuto: Boolean,
    onScanAuto: (Boolean) -> Unit,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    val resumed = lifecycle.lifecycle.currentStateAsState().value.isAtLeast(Lifecycle.State.RESUMED)
    val hasCamera = remember { context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) }
    // A debug build started with the demo extra shows a drawn page in scan mode instead of the camera.
    val demo = BuildConfig.DEBUG && ScanDemo.on
    fun allowed() = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    var granted by remember { mutableStateOf(allowed()) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        granted = it
        onAsked()
    }
    // Coming back from the system settings with the permission given starts the camera.
    LaunchedEffect(resumed) { if (resumed) granted = allowed() }
    LaunchedEffect(canAsk, granted, hasCamera) { if (canAsk && hasCamera && !granted && !asked) permission.launch(Manifest.permission.CAMERA) }

    // The three share one aspect ratio, so the preview, the photo and the frames the outline is found in show the same scene.
    val ratio = remember { ResolutionSelector.Builder().setAspectRatioStrategy(AspectRatioStrategy(AspectRatio.RATIO_4_3, AspectRatioStrategy.FALLBACK_RULE_AUTO)).build() }
    val preview = remember { Preview.Builder().setResolutionSelector(ratio).build() }
    val capture = remember { ImageCapture.Builder().setResolutionSelector(ratio).setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY).build() }
    val analysis = remember {
        ImageAnalysis.Builder()
            .setResolutionSelector(ratio)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
            .also { it.setAnalyzer(scan.feed.executor, scan.feed) }
    }
    var view by remember { mutableStateOf<PreviewView?>(null) }
    var front by rememberSaveable { mutableStateOf(false) }
    var shownFront by remember { mutableStateOf<Boolean?>(null) }
    var camera by remember { mutableStateOf<Camera?>(null) }
    var analysing by remember { mutableStateOf(false) }
    var broken by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var flash by rememberSaveable { mutableIntStateOf(ImageCapture.FLASH_MODE_OFF) }
    var torch by rememberSaveable { mutableStateOf(false) }
    var focus by remember { mutableStateOf<Offset?>(null) }

    // Scanning is with the back camera.
    val useFront = front && !scanning
    val running = resumed && granted && hasCamera
    DisposableEffect(running, useFront, scanning) {
        var provider: ProcessCameraProvider? = null
        var left = false
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (left || !running) return@addListener
            val bound = future.get()
            provider = bound
            val selector = if (useFront) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
            try {
                if (scanning) {
                    try {
                        camera = bound.bindToLifecycle(lifecycle, selector, preview, capture, analysis)
                        analysing = true
                    } catch (e: IllegalArgumentException) {
                        // A camera that cannot run all three still takes pages by hand, without the outline.
                        camera = bound.bindToLifecycle(lifecycle, selector, preview, capture)
                    }
                } else {
                    camera = bound.bindToLifecycle(lifecycle, selector, preview, capture)
                }
                shownFront = useFront
                // Starts at 1x, the main lens.
                camera?.cameraControl?.setZoomRatio(1f)
                broken = false
            } catch (e: Exception) {
                // The camera in use stays; only a first setup that fails means there is none.
                val before = shownFront
                if (before == null) {
                    broken = true
                } else {
                    front = before
                    onFailed(context.getString(R.string.camera_switch_failed))
                }
            }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            left = true
            provider?.unbind(preview, capture, analysis)
            camera = null
            analysing = false
        }
    }

    var zoom by remember { mutableStateOf<ZoomState?>(null) }
    val telephoto = remember(camera) { camera?.let { telephotoOf(context, it) } }
    DisposableEffect(camera) {
        val live = camera?.cameraInfo?.zoomState
        val observer = Observer<ZoomState> { zoom = it }
        live?.observe(lifecycle, observer)
        onDispose { live?.removeObserver(observer) }
    }

    // The shot is tagged for how the phone is held, also when the screen's rotation is locked.
    DisposableEffect(running) {
        val listener = object : OrientationEventListener(context) {
            override fun onOrientationChanged(degrees: Int) {
                if (degrees == ORIENTATION_UNKNOWN) return
                capture.targetRotation = when (degrees) {
                    in 45..134 -> Surface.ROTATION_270
                    in 135..224 -> Surface.ROTATION_180
                    in 225..314 -> Surface.ROTATION_90
                    else -> Surface.ROTATION_0
                }
            }
        }
        if (running && listener.canDetectOrientation()) listener.enable()
        onDispose { listener.disable() }
    }

    // The frames are turned to the screen's rotation, as the preview is, so the outline found in them lands on the page shown.
    val hostView = LocalView.current
    var turned by remember { mutableIntStateOf(0) }
    DisposableEffect(hostView) {
        val displays = context.getSystemService(DisplayManager::class.java)
        val listener = object : DisplayManager.DisplayListener {
            override fun onDisplayChanged(displayId: Int) {
                hostView.display?.let { analysis.targetRotation = it.rotation }
                turned++
            }

            override fun onDisplayAdded(displayId: Int) {}

            override fun onDisplayRemoved(displayId: Int) {}
        }
        hostView.display?.let { analysis.targetRotation = it.rotation }
        displays.registerDisplayListener(listener, null)
        onDispose { displays.unregisterDisplayListener(listener) }
    }
    val frame = {
        turned
        if (demo) {
            FrameInfo(0, ScanDemo.WIDTH, ScanDemo.HEIGHT)
        } else {
            analysis.resolutionInfo?.let { FrameInfo(it.rotationDegrees, it.resolution.width, it.resolution.height) }
        }
    }

    val scope = rememberCoroutineScope()
    val hasFlash = camera?.cameraInfo?.hasFlashUnit() == true
    val message = when {
        !hasCamera || broken -> R.string.camera_none
        !granted && asked -> R.string.camera_denied
        else -> null
    }

    // Scan mode: what the model needs from here.
    val target = targets.firstOrNull { it.id == selected }
    SideEffect {
        scan.filter = scanFilter
        scan.auto = scanAuto
        scan.hasTarget = target != null
    }
    val readyNow by rememberUpdatedState(camera != null)
    DisposableEffect(scanning, demo) {
        if (scanning && !demo) scan.camera = CaptureCamera(capture, ContextCompat.getMainExecutor(context)) { readyNow }
        onDispose { if (!demo) scan.camera = null }
    }
    var pagesOpen by rememberSaveable { mutableStateOf(false) }
    val shotEditing by scan.shotEditing.collectAsState()
    val pageEditing by scan.pageEditing.collectAsState()
    val covered = pagesOpen || shotEditing != null || pageEditing != null
    val attached = scanning && (demo || (analysing && running))
    LaunchedEffect(attached, covered) { scan.setLive(attached, covered) }
    DisposableEffect(Unit) { onDispose { scan.setLive(false, false) } }
    // A cut that finishes after the sheet has closed has nowhere to open: the page stays as it was.
    LaunchedEffect(pageEditing, pagesOpen) { pageEditing?.let { if (!pagesOpen) scan.answer(it, CornerAnswer.Cancel) } }
    // The light is for scanning: it goes off with the mode, and comes back on with a camera that was rebound.
    LaunchedEffect(scanning) { if (!scanning) torch = false }
    LaunchedEffect(camera, torch, scanning) { camera?.cameraControl?.enableTorch(torch && scanning) }

    val zoomControl: @Composable () -> Unit = {
        zoom?.let { state ->
            val stops = lensStops(state.minZoomRatio, state.maxZoomRatio, telephoto)
            if (stops.size > 1) ZoomControl(state.zoomRatio, stops, state.maxZoomRatio) { camera?.cameraControl?.setZoomRatio(it) }
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { PreviewView(it).apply { scaleType = PreviewView.ScaleType.FIT_CENTER }.also { made -> view = made; preview.surfaceProvider = made.surfaceProvider } },
        )
        if (demo && scanning) {
            val picture = remember { ScanDemo.picture() }
            Box(Modifier.fillMaxSize().background(Color.Black))
            picture?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
        }
        Box(
            Modifier.fillMaxSize()
                .pointerInput(camera) {
                    detectTapGestures { at ->
                        val current = camera ?: return@detectTapGestures
                        val point = view?.meteringPointFactory?.createPoint(at.x, at.y) ?: return@detectTapGestures
                        current.cameraControl.startFocusAndMetering(FocusMeteringAction.Builder(point).build())
                        focus = at
                    }
                }
                .pointerInput(camera) {
                    detectTransformGestures { _, _, zoom, _ ->
                        val current = camera ?: return@detectTransformGestures
                        val state = current.cameraInfo.zoomState.value ?: return@detectTransformGestures
                        current.cameraControl.setZoomRatio((state.zoomRatio * zoom).coerceIn(state.minZoomRatio, state.maxZoomRatio))
                    }
                },
        )
        focus?.let { at ->
            LaunchedEffect(at) {
                delay(1200)
                focus = null
            }
            Box(Modifier.offset { IntOffset((at.x - 36.dp.toPx()).toInt(), (at.y - 36.dp.toPx()).toInt()) }.size(72.dp).border(1.5.dp, Color.White, RoundedCornerShape(4.dp)))
        }
        if (scanning) ScanOutline(scan, frame)

        Column(Modifier.align(Alignment.Center), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (targets.isEmpty()) {
                Panel {
                    Text(stringResource(R.string.camera_pair_title), color = Color.White, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
                    Button(onClick = onPair) { Text(stringResource(R.string.pair_device)) }
                }
            }
            if (message != null && !(demo && scanning)) {
                Panel {
                    Text(stringResource(message), color = Color.White, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
                    if (message == R.string.camera_denied) {
                        Button(onClick = {
                            context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)))
                        }) { Text(stringResource(R.string.open_settings)) }
                    }
                }
            }
        }

        if (scanning) {
            ScanChrome(
                scan = scan,
                targets = targets,
                selected = selected,
                onSelect = onSelect,
                entries = entries,
                cameraReady = demo || camera != null,
                auto = scanAuto,
                onAuto = onScanAuto,
                filter = scanFilter,
                onFilter = onScanFilter,
                hasTorch = hasFlash,
                torch = torch,
                onTorch = { torch = it },
                onScanning = onScanning,
                zoom = zoomControl,
                onPages = { pagesOpen = true },
            )
        } else {
            PhotoChrome(
                targets = targets,
                selected = selected,
                onSelect = onSelect,
                hasFlash = hasFlash,
                flash = flash,
                onFlash = { flash = nextFlash(flash) },
                format = format,
                onFormat = onFormat,
                onScanning = onScanning,
                problem = problem,
                zoom = zoomControl,
                shot = shot,
                entries = entries,
                onHistory = onHistory,
                canShoot = camera != null && !busy && targets.isNotEmpty(),
                onShoot = {
                    onClearProblem()
                    busy = true
                    scope.launch {
                        val file = newFile()
                        capture.flashMode = if (hasFlash) flash else ImageCapture.FLASH_MODE_OFF
                        capture.takePicture(
                            ImageCapture.OutputFileOptions.Builder(file).build(),
                            ContextCompat.getMainExecutor(context),
                            object : ImageCapture.OnImageSavedCallback {
                                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                                    busy = false
                                    onTaken(file)
                                }

                                override fun onError(exception: ImageCaptureException) {
                                    busy = false
                                    file.delete()
                                    onFailed(context.getString(R.string.camera_photo_failed))
                                }
                            },
                        )
                    }
                },
                canFlip = camera != null && !busy,
                onFlip = { front = !front },
            )
        }
    }

    if (pagesOpen) ScanPagesSheet(scan, target?.name) { pagesOpen = false }
    shotEditing?.let { request -> CornerEditorDialog(request) { scan.answer(request, it) } }
    pageEditing?.let { request -> CornerEditorDialog(request) { scan.answer(request, it) } }
}

/** Takes a page's photo for the scan model: a JPEG in memory, tagged for how the phone is held, with the flash left to the light. */
private class CaptureCamera(private val capture: ImageCapture, private val executor: Executor, private val isReady: () -> Boolean) : ScanCamera {
    override val ready get() = isReady()

    override suspend fun takePhoto(): ByteArray? = suspendCancellableCoroutine { done ->
        capture.flashMode = ImageCapture.FLASH_MODE_OFF
        val out = ByteArrayOutputStream()
        capture.takePicture(
            ImageCapture.OutputFileOptions.Builder(out).build(),
            executor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) = done.resume(out.toByteArray())

                override fun onError(exception: ImageCaptureException) = done.resume(null)
            },
        )
    }
}
