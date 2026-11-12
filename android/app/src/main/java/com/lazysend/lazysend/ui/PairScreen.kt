package com.lazysend.lazysend.ui

import android.Manifest
import android.content.ClipboardManager
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.lazysend.lazysend.BuildConfig
import com.lazysend.lazysend.R
import java.util.concurrent.Executors

sealed interface PairUi {
    data object Scanning : PairUi

    /** The PC is asking its user; [checkCode] is what both screens should show. */
    data class Waiting(val checkCode: String) : PairUi

    data class Failed(val message: String) : PairUi

    data class Paired(val pcName: String) : PairUi
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PairScreen(state: PairUi, onCode: (String, String?) -> Unit, onRetry: () -> Unit, onBack: () -> Unit, scanner: Boolean = true) {
    Scaffold(
        topBar = {
            TopAppBar(title = { Text(stringResource(R.string.pair_title)) }, navigationIcon = { TextButton(onClick = onBack) { Text(stringResource(R.string.back)) } })
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            when (state) {
                PairUi.Scanning -> Scan(onCode, scanner)
                is PairUi.Waiting -> {
                    Text(stringResource(R.string.pair_waiting_title), style = MaterialTheme.typography.headlineSmall)
                    Text(stringResource(R.string.pair_waiting_body))
                    Text(stringResource(R.string.pair_check_code), style = MaterialTheme.typography.labelLarge)
                    Text(state.checkCode, style = MaterialTheme.typography.displayMedium, color = MaterialTheme.colorScheme.primary)
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                }
                is PairUi.Failed -> {
                    Text(state.message, color = MaterialTheme.colorScheme.error)
                    Button(onClick = onRetry) { Text(stringResource(R.string.try_again)) }
                }
                is PairUi.Paired -> {
                    Text(stringResource(R.string.pair_done, state.pcName), style = MaterialTheme.typography.headlineSmall)
                    Button(onClick = onBack) { Text(stringResource(R.string.done)) }
                }
            }
        }
    }
}

@Composable
private fun Scan(onCode: (String, String?) -> Unit, scanner: Boolean) {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var asked by remember { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it; asked = true }
    var pasted by remember { mutableStateOf("") }
    var extra by remember { mutableStateOf("") }

    if (scanner && !granted && !asked) permission.launch(Manifest.permission.CAMERA)
    if (scanner && granted) {
        Text(stringResource(R.string.pair_scan_hint))
        QrScanner(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(16.dp))) { onCode(it, extra.ifBlank { null }) }
    } else if (asked) {
        Text(stringResource(R.string.pair_camera_denied))
    }
    OutlinedTextField(
        value = pasted,
        onValueChange = { pasted = it },
        label = { Text(stringResource(R.string.pair_paste)) },
        placeholder = { Text(stringResource(R.string.pair_paste_hint)) },
        modifier = Modifier.fillMaxWidth(),
        maxLines = 3,
    )
    if (BuildConfig.DEBUG) {
        OutlinedTextField(
            value = extra,
            onValueChange = { extra = it },
            label = { Text(stringResource(R.string.pair_debug_address)) },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
        )
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = { context.getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.text?.let { pasted = it.toString() } }) { Text(stringResource(R.string.paste)) }
        Button(onClick = { onCode(pasted, extra.ifBlank { null }) }, enabled = pasted.isNotBlank()) { Text(stringResource(R.string.pair_connect)) }
    }
}

@Composable
private fun QrScanner(modifier: Modifier, onCode: (String) -> Unit) {
    val lifecycle = LocalLifecycleOwner.current
    val latest by rememberLatest(onCode)
    AndroidView(
        modifier = modifier,
        factory = { context ->
            PreviewView(context).also { view ->
                val future = ProcessCameraProvider.getInstance(context)
                future.addListener({
                    val provider = future.get()
                    val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                    val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                    val reader = MultiFormatReader().apply {
                        setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true))
                    }
                    analysis.setAnalyzer(Executors.newSingleThreadExecutor()) { image -> decode(reader, image)?.let { ContextCompat.getMainExecutor(context).execute { latest(it) } } }
                    provider.unbindAll()
                    provider.bindToLifecycle(lifecycle, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                }, ContextCompat.getMainExecutor(context))
            }
        },
    )
}

@Composable
private fun rememberLatest(block: (String) -> Unit) = remember { mutableStateOf(block) }.also { it.value = block }

private fun decode(reader: MultiFormatReader, image: ImageProxy): String? = image.use {
    val plane = it.planes[0]
    val bytes = ByteArray(plane.buffer.remaining()).also { b -> plane.buffer.get(b) }
    val source = PlanarYUVLuminanceSource(bytes, plane.rowStride, it.height, 0, 0, it.width, it.height, false)
    try {
        reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
    } catch (e: NotFoundException) {
        null
    } finally {
        reader.reset()
    }
}
