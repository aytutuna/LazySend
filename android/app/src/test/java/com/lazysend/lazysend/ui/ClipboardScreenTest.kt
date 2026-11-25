package com.lazysend.lazysend.ui

import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
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
class ClipboardScreenTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(accepts: Boolean, sent: MutableList<String>) {
        compose.setContent {
            LazySendTheme(dark = false) {
                ClipboardScreen(PcRow("pc", "Office", null), emptyList(), null, {}, { sent += it; accepts }, {}, MainActions())
            }
        }
    }

    @Test
    fun aTextThatWasNotTakenStaysInTheBox() {
        val sent = mutableListOf<String>()
        val longText = "a text the box has to keep"
        show(accepts = false, sent)

        compose.onNode(hasSetTextAction()).performTextInput(longText)
        compose.onNodeWithText("Send").performClick()

        assertEquals(listOf(longText), sent)
        compose.onNodeWithText(longText).assertExists()
    }

    @Test
    fun aTextThatWasTakenClearsTheBox() {
        val sent = mutableListOf<String>()
        show(accepts = true, sent)

        compose.onNode(hasSetTextAction()).performTextInput("hello")
        compose.onNodeWithText("Send").performClick()

        assertEquals(listOf("hello"), sent)
        compose.onNodeWithText("hello").assertDoesNotExist()
    }
}
