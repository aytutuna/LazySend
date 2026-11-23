package com.lazysend.lazysend.ui

import androidx.camera.core.ImageCapture
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import com.github.takahirom.roborazzi.captureRoboImage
import com.lazysend.lazysend.scan.CaptureFilter
import com.lazysend.lazysend.scan.CapturePlacement
import com.lazysend.lazysend.scan.CaptureQuality
import com.lazysend.lazysend.scan.CaptureState
import com.lazysend.lazysend.scan.CornerEditorModel
import com.lazysend.lazysend.scan.CornerRequest
import com.lazysend.lazysend.scan.LiveQuadUpdate
import com.lazysend.lazysend.scan.PagePipeline
import com.lazysend.lazysend.scan.ScanDemo
import com.lazysend.lazysend.scan.ScanFrameFeed
import com.lazysend.lazysend.scan.ScanModel
import com.lazysend.lazysend.scan.ViewSize
import com.lazysend.lazysend.transfer.PhotoFormat
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** The scan mode of the camera tab, its pages sheet and the corner editor, over a drawn page in place of the camera. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi", application = android.app.Application::class)
class ScanScreenshotsTest {
    @get:Rule
    val compose = createComposeRule()

    private val pcs = listOf(PcRow("desktop-0001", "Aytu's PC", "USB"))
    private val steady = ScanDemo.update
    private val moving = LiveQuadUpdate(
        steady.outline, CaptureState.Moving, 0.0, 0.0, isSteady = false, placement = CapturePlacement.Far,
    )

    private fun capture(name: String, content: @Composable () -> Unit) {
        compose.setContent { LazySendTheme(dark = false, content = content) }
        compose.waitForIdle()
        compose.onRoot().captureRoboImage(File(System.getProperty("lazysend.shotsDir") ?: "build/shots", "$name.png").path)
    }

    private fun model(live: LiveQuadUpdate?, filters: List<CaptureFilter> = emptyList()): ScanModel {
        val scan = ScanModel(
            CoroutineScope(Dispatchers.Unconfined), null, null, ScanFrameFeed(null), { "" }, Dispatchers.Unconfined, fixedLive = live,
        )
        scan.camera = ScanDemo.camera
        scan.hasTarget = true
        for (filter in filters) {
            val page = PagePipeline.page(ScanDemo.frame, ScanDemo.outline, filter)!!
            scan.add(page, ScanDemo.photo)
        }
        if (live != null) scan.setLive(attached = true, covered = false)
        return scan
    }

    private val threePages = listOf(CaptureFilter.Enhanced, CaptureFilter.Grayscale, CaptureFilter.BlackAndWhite)
    private val zoomStops: @Composable () -> Unit = { ZoomControl(1f, listOf(0.6f, 1f, 2f, 5f), 8f) {} }

    @Composable
    private fun Viewfinder(content: @Composable () -> Unit) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            Image(ScanDemo.picture()!!.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
            content()
        }
    }

    @Composable
    private fun Scanning(scan: ScanModel, targets: List<PcRow> = pcs, auto: Boolean = true) {
        Viewfinder {
            ScanOutline(scan) { FrameInfo(0, ScanDemo.WIDTH, ScanDemo.HEIGHT) }
            ScanChrome(
                scan = scan, targets = targets, selected = targets.firstOrNull()?.id, onSelect = {}, entries = emptyList(), cameraReady = true,
                auto = auto, onAuto = {}, filter = CaptureFilter.Enhanced, onFilter = {}, hasTorch = true, torch = false, onTorch = {},
                onScanning = {}, zoom = zoomStops, onPages = {},
            )
        }
    }

    @Test
    fun scanSteady() = capture("scan-steady") { Scanning(model(steady, threePages)) }

    @Test
    fun scanFarMoving() = capture("scan-far") { Scanning(model(moving, threePages.take(1))) }

    @Test
    fun scanBlurry() = capture("scan-blurry") {
        Scanning(model(steady.copy(quality = CaptureQuality.Blurry, progress = 0.4), emptyList()))
    }

    @Test
    fun scanLongName() = capture("scan-long-name") {
        Scanning(model(steady, threePages), listOf(PcRow("desktop-0001", "Aytu's workstation in the basement office", "USB")))
    }

    @Test
    fun scanControls() {
        compose.setContent { LazySendTheme(dark = false) { Scanning(model(steady, threePages)) } }
        compose.onNodeWithText("Controls").performClick()
        compose.waitForIdle()
        compose.onRoot().captureRoboImage(File(System.getProperty("lazysend.shotsDir") ?: "build/shots", "scan-controls.png").path)
    }

    @Test
    fun photoMode() = capture("camera-photo") {
        Viewfinder {
            PhotoChrome(
                targets = pcs, selected = "desktop-0001", onSelect = {}, hasFlash = true, flash = ImageCapture.FLASH_MODE_AUTO, onFlash = {},
                format = PhotoFormat.Jpeg, onFormat = {}, onScanning = {}, problem = null, zoom = zoomStops, shot = null, entries = emptyList(),
                onHistory = {}, canShoot = true, onShoot = {}, canFlip = true, onFlip = {},
            )
        }
    }

    @Test
    fun photoModeLongName() = capture("camera-photo-long-name") {
        val long = listOf(PcRow("desktop-0001", "Aytu's workstation in the basement office", "USB"))
        Viewfinder {
            PhotoChrome(
                targets = long, selected = "desktop-0001", onSelect = {}, hasFlash = true, flash = ImageCapture.FLASH_MODE_OFF, onFlash = {},
                format = PhotoFormat.Original, onFormat = {}, onScanning = {}, problem = null, zoom = zoomStops, shot = null, entries = emptyList(),
                onHistory = {}, canShoot = true, onShoot = {}, canFlip = true, onFlip = {},
            )
        }
    }

    @Test
    fun pagesSheet() = capture("scan-pages") {
        Surface(Modifier.fillMaxSize()) { ScanPagesContent(model(null, threePages), "Aytu's PC") {} }
    }

    private val request = CornerRequest(ScanDemo.frame, ScanDemo.photo, ScanDemo.outline, CaptureFilter.Enhanced, null)

    private fun waitForPhoto() {
        // The photo is made into a bitmap off the main thread.
        Thread.sleep(800)
        compose.waitForIdle()
    }

    @Test
    fun cornerEditor() {
        compose.setContent { LazySendTheme(dark = false) { Surface(Modifier.fillMaxSize()) { CornerEditor(request) {} } } }
        waitForPhoto()
        compose.onRoot().captureRoboImage(File(System.getProperty("lazysend.shotsDir") ?: "build/shots", "scan-corners.png").path)
    }

    @Test
    fun cornerEditorLoupe() {
        compose.setContent { LazySendTheme(dark = false) { Surface(Modifier.fillMaxSize()) { CornerEditor(request) {} } } }
        waitForPhoto()
        val stage = compose.onNodeWithContentDescription("Page corners")
        val node = stage.fetchSemanticsNode()
        val density = 3f
        val size = ViewSize(node.size.width / density.toDouble(), node.size.height / density.toDouble())
        val model = CornerEditorModel(request.photo.width, request.photo.height, request.corners)
        val corner = model.handlePoint(0, model.shownFrame(size))
        stage.performTouchInput { down(Offset((corner.x * density).toFloat(), (corner.y * density).toFloat())) }
        compose.waitForIdle()
        compose.onRoot().captureRoboImage(File(System.getProperty("lazysend.shotsDir") ?: "build/shots", "scan-corners-loupe.png").path)
        stage.performTouchInput { up() }
    }

    @Test
    fun cornerEditorRecut() {
        val recut = CornerRequest(ScanDemo.frame, ScanDemo.photo, ScanDemo.outline, CaptureFilter.Original, java.util.UUID.randomUUID())
        compose.setContent { LazySendTheme(dark = true) { Surface(Modifier.fillMaxSize()) { CornerEditor(recut) {} } } }
        waitForPhoto()
        compose.onRoot().captureRoboImage(File(System.getProperty("lazysend.shotsDir") ?: "build/shots", "scan-corners-recut-dark.png").path)
    }
}
