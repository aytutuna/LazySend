package com.lazysend.lazysend.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import com.lazysend.lazysend.scan.CaptureFilter
import com.lazysend.lazysend.scan.CornerEditorModel
import com.lazysend.lazysend.scan.CornerRequest
import com.lazysend.lazysend.scan.ScanDemo
import com.lazysend.lazysend.scan.ViewSize
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi", application = android.app.Application::class)
class CornerEditorButtonsTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun resetEnablesAfterADrag() {
        val request = CornerRequest(ScanDemo.frame, ScanDemo.photo, ScanDemo.outline, CaptureFilter.Enhanced, null)
        compose.setContent { LazySendTheme(dark = false) { Surface(Modifier.fillMaxSize()) { CornerEditor(request) {} } } }
        Thread.sleep(800)
        compose.waitForIdle()
        compose.onNodeWithText("Reset").assertIsNotEnabled()

        val stage = compose.onNodeWithContentDescription("Page corners")
        val node = stage.fetchSemanticsNode()
        val density = 3f
        val size = ViewSize(node.size.width / density.toDouble(), node.size.height / density.toDouble())
        val model = CornerEditorModel(request.photo.width, request.photo.height, request.corners)
        val from = model.handlePoint(0, model.shownFrame(size))
        val to = Offset(((from.x + 30) * density).toFloat(), ((from.y + 30) * density).toFloat())
        stage.performTouchInput {
            down(Offset((from.x * density).toFloat(), (from.y * density).toFloat()))
            moveTo(to)
            up()
        }
        compose.waitForIdle()
        compose.onNodeWithText("Reset").assertIsEnabled()
    }
}
