package com.lazysend.lazysend.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import com.lazysend.lazysend.data.Direction
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.EntryState
import com.lazysend.lazysend.data.TimelineEntry
import java.io.File
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Renders the screens with fixed data. The PNGs are written only by Roborazzi's record task:
 * gradlew recordRoborazziDebug -Plazysend.shotsDir=<folder>. A plain test run still renders every screen.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi", application = android.app.Application::class)
class ScreenshotsTest {
    @get:Rule
    val compose = createComposeRule()

    private val pcs = listOf(PcRow("desktop-0001", "Aytu's PC", "USB"))
    private val noon = 1_760_000_000_000L

    private fun entry(id: String, kind: EntryKind, direction: Direction, title: String, state: EntryState = EntryState.Done, offset: Long = 0, init: TimelineEntry.() -> TimelineEntry = { this }) =
        TimelineEntry(id, noon - offset * 60_000, direction, kind, "Aytu's PC", title, state = state).init()

    private fun capture(name: String, content: @Composable () -> Unit) {
        compose.setContent { LazySendTheme(dark = false, content = content) }
        compose.waitForIdle()
        compose.onRoot().captureRoboImage(File(System.getProperty("lazysend.shotsDir") ?: "build/shots", "$name.png").path)
    }

    private val timeline = listOf(
        entry("g", EntryKind.Gallery, Direction.Sent, "Photos and videos", EntryState.Active, 1) {
            copy(count = 412, totalCount = 1385, bytes = 1_900_000_000, totalBytes = 6_400_000_000)
        },
        entry("1", EntryKind.Text, Direction.Received, "https://alazy.app/send/", offset = 3) { copy(kind = EntryKind.Link) },
        entry("2", EntryKind.File, Direction.Received, "Quarterly report.pdf", offset = 9) { copy(bytes = 2_400_000, totalBytes = 2_400_000) },
        entry("3", EntryKind.File, Direction.Sent, "IMG_20261104_181530.jpg", EntryState.Active, 12) { copy(bytes = 3_100_000, totalBytes = 8_700_000) },
        entry("4", EntryKind.Text, Direction.Sent, "The door code is 4821", offset = 40),
        entry("5", EntryKind.File, Direction.Sent, "holiday.mp4", EntryState.Failed, 95) { copy(detail = "Aytu's PC is not reachable.") },
    )

    @Test
    fun mainScreen() = capture("main") {
        MainScreen(MainState(pcs, "desktop-0001", timeline.drop(1)), MainActions())
    }

    @Test
    fun galleryProgress() = capture("gallery-sync") {
        MainScreen(MainState(pcs, "desktop-0001", listOf(timeline.first()), PhotoAccess.Partial), MainActions())
    }

    @Test
    fun galleryPaused() = capture("gallery-paused") {
        MainScreen(
            MainState(pcs.map { it.copy(link = null) }, "desktop-0001", listOf(timeline.first().copy(state = EntryState.Paused, detail = "Waiting for Aytu's PC"))),
            MainActions(),
        )
    }

    @Test
    fun emptyScreen() = capture("main-empty") { MainScreen(MainState(emptyList(), null, emptyList()), MainActions()) }

    @Test
    fun pairScanning() = capture("pair-scan") { PairScreen(PairUi.Scanning, { _, _ -> }, {}, {}, scanner = false) }

    @Test
    fun pairWaiting() = capture("pair-approve") { PairScreen(PairUi.Waiting("066 051"), { _, _ -> }, {}, {}, scanner = false) }

    @Test
    fun pairDeclined() = capture("pair-declined") { PairScreen(PairUi.Failed("Pairing was declined on the computer."), { _, _ -> }, {}, {}, scanner = false) }

    @Test
    fun sendScreen() = capture("send") { SendScreen("Aytu's PC", null, {}, {}, {}, {}) }

    @Test
    fun pcsScreen() = capture("pcs") { PcsScreen(pcs, {}, {}, {}) }

    private val receiving = ReceiveUi(
        com.lazysend.lazysend.host.ReceiveState(
            running = true, port = 52734, link = "Wi-Fi",
            pairing = com.lazysend.lazysend.host.PairingInfo(
                "lazysend://pair?v=1&id=host-test-0001&n=Pixel%209&fp=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&a=192.168.1.20&p=52734&t=dG9rZW4tdG9rZW4tdG9r",
                "7KQ2-M9XD", "987 292", "066 051", noon + 300_000,
            ),
        ),
        guests = listOf("Aytu's iPhone"),
    )

    @Test
    fun receiveScreen() = capture("receive") { ReceiveScreen(receiving, { _, _ -> }, {}, {}, {}, {}, {}) }

    @Test
    fun receiveApproval() = capture("receive-approve") {
        ReceiveScreen(receiving.copy(approval = com.lazysend.lazysend.host.Approval("Pixel 9", "android", "987 292")), { _, _ -> }, {}, {}, {}, {}, {})
    }
}
