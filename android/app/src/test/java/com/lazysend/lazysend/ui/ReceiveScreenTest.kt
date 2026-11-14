package com.lazysend.lazysend.ui

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.lazysend.lazysend.host.PairingInfo
import com.lazysend.lazysend.host.ReceiveState
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], application = android.app.Application::class)
class ReceiveScreenTest {
    @get:Rule
    val compose = createComposeRule()

    private val running = ReceiveState(running = true, port = 52734, link = "Wi-Fi")

    @Test
    fun aDeniedLocalNetworkPermissionIsSaidAndCanBeAskedAgain() {
        var asked = 0
        compose.setContent {
            LazySendTheme(dark = false) { ReceiveScreen(ReceiveUi(running), { _, _ -> }, {}, {}, {}, {}, {}, localNetworkDenied = true, onAllowNetwork = { asked++ }) }
        }
        compose.onNodeWithText("Access to devices on your network is off", substring = true).assertExists()
        compose.onNodeWithText("Allow").performClick()
        assertEquals(1, asked)
    }

    @Test
    fun aClosedCodeOffersANewOne() {
        var asked = 0
        val closed = PairingInfo("lazysend://pair?v=1", "7KQ2-M9XD", "987 292", "066 051", 0, closed = true)
        compose.setContent {
            LazySendTheme(dark = false) { ReceiveScreen(ReceiveUi(running.copy(pairing = closed)), { _, _ -> }, {}, {}, { asked++ }, {}, {}) }
        }
        compose.onNodeWithText("Too many wrong codes were tried", substring = true).assertExists()
        compose.onNodeWithText("7KQ2-M9XD").assertDoesNotExist()
        compose.onNodeWithText("Get a new code").performClick()
        assertEquals(1, asked)
    }
}
