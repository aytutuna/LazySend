package com.lazysend.lazysend.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.lazysend.lazysend.host.Approval
import com.lazysend.lazysend.host.ReceiveState
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], application = android.app.Application::class)
class ApprovalDialogTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(approval: Approval, answer: (Approval, Boolean) -> Unit) {
        var shown by mutableStateOf<Approval?>(approval)
        compose.setContent {
            LazySendTheme(dark = false) {
                ReceiveScreen(ReceiveUi(ReceiveState(), shown), { a, allow -> answer(a, allow); shown = null }, {}, {}, {}, {}, {})
            }
        }
    }

    @Test
    fun allowAllowsAndTheDialogGoingAwayChangesNothing() {
        val approval = Approval("Pixel 9", "android", "987 292")
        show(approval) { a, allow -> a.respond(allow) }
        compose.onNodeWithText("987 292").assertExists()
        assertFalse(approval.answer.isCompleted)
        compose.onNodeWithText("Allow").performClick()
        compose.waitForIdle()
        assertTrue(approval.answer.isCompleted)
        assertEquals(true, runBlocking { approval.answer.await() })
        compose.onNodeWithText("Allow").assertDoesNotExist()
    }

    @Test
    fun dontAllowDeclines() {
        val approval = Approval("Pixel 9", "android", "987 292")
        show(approval) { a, allow -> a.respond(allow) }
        compose.onNodeWithText("Don't allow").performClick()
        compose.waitForIdle()
        assertEquals(false, runBlocking { approval.answer.await() })
    }

    @Test
    fun aLateDeclineAfterAllowStaysAllowed() {
        val approval = Approval("Pixel 9", "android", "987 292")
        show(approval) { a, allow -> a.respond(allow) }
        compose.onNodeWithText("Allow").performClick()
        approval.respond(false)
        assertEquals(true, runBlocking { approval.answer.await() })
    }
}
