package com.lazysend.lazysend.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.lazysend.lazysend.R
import com.lazysend.lazysend.data.Direction
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.EntryState
import com.lazysend.lazysend.data.TimelineEntry
import java.io.File
import kotlinx.coroutines.delay

private val Scrim = Color.Black.copy(alpha = 0.45f)

/**
 * The camera tab: a live viewfinder, and every photo goes to the chosen device's clipboard as soon as it is taken.
 * The camera is held only while this screen is composed and the activity is resumed.
 */
@Composable
fun CameraScreen(
    canAsk: Boolean,
    targets: List<PcRow>,
    selected: String?,
    entries: List<TimelineEntry>,
    shot: Shot?,
    problem: String?,
    onSelect: (String) -> Unit,
    onPair: () -> Unit,
    onHistory: () -> Unit,
    newFile: () -> File,
    onTaken: (File) -> Unit,
    onFailed: (String) -> Unit,
    onClearProblem: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    val resumed = lifecycle.lifecycle.currentStateAsState().value.isAtLeast(Lifecycle.State.RESUMED)
    val hasCamera = remember { context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) }
    fun allowed() = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    var granted by remember { mutableStateOf(allowed()) }
    var asked by rememberSaveable { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        granted = it
        asked = true
    }
    // Coming back from the system settings with the permission given starts the camera.
    LaunchedEffect(resumed) { if (resumed) granted = allowed() }
    LaunchedEffect(canAsk, granted, hasCamera) { if (canAsk && hasCamera && !granted && !asked) permission.launch(Manifest.permission.CAMERA) }

    val preview = remember { Preview.Builder().build() }
    val capture = remember { ImageCapture.Builder().setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY).build() }
    var view by remember { mutableStateOf<PreviewView?>(null) }
    var front by rememberSaveable { mutableStateOf(false) }
    var shownFront by remember { mutableStateOf<Boolean?>(null) }
    var camera by remember { mutableStateOf<Camera?>(null) }
    var broken by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var flash by rememberSaveable { mutableIntStateOf(ImageCapture.FLASH_MODE_OFF) }
    var focus by remember { mutableStateOf<Offset?>(null) }

    val running = resumed && granted && hasCamera
    DisposableEffect(running, front) {
        var provider: ProcessCameraProvider? = null
        var left = false
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (left || !running) return@addListener
            val bound = future.get()
            provider = bound
            try {
                camera = bound.bindToLifecycle(lifecycle, if (front) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA, preview, capture)
                shownFront = front
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
            provider?.unbind(preview, capture)
            camera = null
        }
    }

    val hasFlash = camera?.cameraInfo?.hasFlashUnit() == true
    val message = when {
        !hasCamera || broken -> R.string.camera_none
        !granted && asked -> R.string.camera_denied
        else -> null
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { PreviewView(it).apply { scaleType = PreviewView.ScaleType.FIT_CENTER }.also { made -> view = made; preview.surfaceProvider = made.surfaceProvider } },
        )
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

        Column(Modifier.align(Alignment.Center), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (targets.isEmpty()) {
                Panel {
                    Text(stringResource(R.string.camera_pair_title), color = Color.White, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
                    Button(onClick = onPair) { Text(stringResource(R.string.pair_device)) }
                }
            }
            if (message != null) {
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

        Column(Modifier.fillMaxSize().statusBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                if (hasFlash) FlashButton(flash) { flash = nextFlash(flash) }
                Box(Modifier.weight(1f))
                targets.firstOrNull { it.id == selected }?.let { Target(it, targets, onSelect) }
            }
            problem?.let {
                Text(it, Modifier.padding(8.dp).background(MaterialTheme.colorScheme.error, RoundedCornerShape(50)).padding(horizontal = 12.dp, vertical = 6.dp), color = MaterialTheme.colorScheme.onError, style = MaterialTheme.typography.bodySmall)
            }
            Box(Modifier.weight(1f))
            val ready = camera != null && !busy && targets.isNotEmpty()
            Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 20.dp), verticalAlignment = Alignment.Top) {
                Box(Modifier.weight(1f), contentAlignment = Alignment.TopStart) { Thumb(shot, entries, targets.firstOrNull { it.id == selected }?.name, onHistory) }
                Shutter(ready) {
                    val file = newFile()
                    onClearProblem()
                    capture.flashMode = if (hasFlash) flash else ImageCapture.FLASH_MODE_OFF
                    busy = true
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
                Box(Modifier.weight(1f), contentAlignment = Alignment.TopEnd) {
                    val flipOn = camera != null && !busy
                    Box(
                        Modifier.size(52.dp).alpha(if (flipOn) 1f else 0.4f).clip(CircleShape).background(Scrim).clickable(enabled = flipOn) { front = !front },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(painterResource(R.drawable.ic_flip), stringResource(R.string.camera_flip), tint = Color.White)
                    }
                }
            }
        }
    }
}

private fun nextFlash(mode: Int) = when (mode) {
    ImageCapture.FLASH_MODE_OFF -> ImageCapture.FLASH_MODE_AUTO
    ImageCapture.FLASH_MODE_AUTO -> ImageCapture.FLASH_MODE_ON
    else -> ImageCapture.FLASH_MODE_OFF
}

@Composable
private fun FlashButton(mode: Int, onClick: () -> Unit) {
    val (icon, label) = when (mode) {
        ImageCapture.FLASH_MODE_AUTO -> R.drawable.ic_flash_auto to R.string.flash_auto
        ImageCapture.FLASH_MODE_ON -> R.drawable.ic_flash_on to R.string.flash_on
        else -> R.drawable.ic_flash_off to R.string.flash_off
    }
    Box(Modifier.size(40.dp).clip(CircleShape).background(Scrim).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(painterResource(icon), stringResource(label), tint = if (mode == ImageCapture.FLASH_MODE_OFF) Color.White else Color.Yellow)
    }
}

@Composable
private fun Target(current: PcRow, all: List<PcRow>, onSelect: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Text(
            current.name,
            Modifier.clip(RoundedCornerShape(50)).background(Scrim).clickable { open = true }.padding(horizontal = 14.dp, vertical = 8.dp),
            color = Color.White,
            style = MaterialTheme.typography.labelLarge,
        )
        DropdownMenu(open, { open = false }) {
            all.forEach { row ->
                DropdownMenuItem(
                    text = { Text(row.name) },
                    trailingIcon = { if (row.id == current.id) Icon(painterResource(R.drawable.ic_check), null) },
                    onClick = {
                        open = false
                        onSelect(row.id)
                    },
                )
            }
        }
    }
}

@Composable
private fun Panel(content: @Composable () -> Unit) {
    Column(
        Modifier.padding(16.dp).background(Color(0xFF2A2A2A), RoundedCornerShape(14.dp)).padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) { content() }
}

@Composable
private fun Shutter(enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(76.dp).alpha(if (enabled) 1f else 0.4f).border(4.dp, Color.White, CircleShape).padding(7.dp).clip(CircleShape).background(Color.White)
            .clickable(enabled = enabled, onClick = onClick),
    )
}

@Composable
private fun Thumb(shot: Shot?, entries: List<TimelineEntry>, target: String?, onClick: () -> Unit) {
    val entry = shot?.let { s -> entries.firstOrNull { it.direction == Direction.Sent && it.kind == EntryKind.File && it.title == s.name } }
    var hidden by remember(shot?.name) { mutableStateOf(false) }
    LaunchedEffect(entry?.state, shot?.name) {
        if (entry?.state == EntryState.Done) {
            hidden = false
            delay(3000)
            hidden = true
        }
    }
    val who = entry?.pcName ?: target
    val line = when {
        shot == null || who == null -> null
        entry?.state == EntryState.Done -> if (hidden) null else stringResource(R.string.camera_sent_to, who)
        entry?.state == EntryState.Failed -> stringResource(R.string.state_failed)
        else -> stringResource(R.string.camera_waiting, who)
    }
    Column(Modifier.clickable(onClick = onClick), horizontalAlignment = Alignment.Start) {
        Box(Modifier.size(52.dp).clip(RoundedCornerShape(8.dp)).background(Color.White.copy(alpha = 0.15f))) {
            shot?.thumbnail?.let { Image(it.asImageBitmap(), stringResource(R.string.camera_history), Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
        }
        if (line != null) Text(line, color = Color.White, style = MaterialTheme.typography.labelSmall, maxLines = 1)
    }
}
