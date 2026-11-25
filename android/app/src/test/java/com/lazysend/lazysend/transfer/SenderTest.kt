package com.lazysend.lazysend.transfer

import android.app.Application
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import com.lazysend.lazysend.data.EntryState
import com.lazysend.lazysend.data.Pc
import com.lazysend.lazysend.data.PcStore
import com.lazysend.lazysend.data.Timeline
import com.lazysend.lazysend.host.CLIP_MAX_AGE_MS
import com.lazysend.lazysend.link.FakePc
import com.lazysend.lazysend.link.TEST_SECRET
import com.lazysend.lazysend.link.encodeBase64Url
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], application = Application::class)
class SenderTest {
    private val pc = FakePc()
    private val dir = File.createTempFile("sender", "").also { it.delete(); it.mkdirs() }
    private val store = PcStore(File(dir, "pcs.json"), { it }, { it })
    private val timeline = Timeline(File(dir, "timeline.json"))
    private val paired = Pc("desktop-test-01", "Test PC", encodeBase64Url(pc.pin), listOf(pc.endpoint.host), pc.endpoint.port, TEST_SECRET)

    @After
    fun stop() {
        pc.close()
        dir.deleteRecursively()
    }

    private var now = 1_800_000_000_000L

    private fun sender(vararg assets: Asset): Sender {
        val context = ApplicationProvider.getApplicationContext<Application>()
        store.put(paired)
        val list = object : MediaAssets(context) {
            override fun list() = assets.toList()
        }
        return Sender(context, PcConnector(store, null), timeline, list, { now }, Outgoing(File(dir, "outgoing")))
    }

    private fun keptCopies() = File(dir, "outgoing").listFiles().orEmpty().filter { it.name != "list.json" }

    @Test
    fun aNoteGoesWithASendId() = runBlocking {
        assertEquals(null, sender().sendText(paired, "hello"))

        assertEquals(22, pc.items.single().sendId!!.length)
    }

    @Test
    fun theClipFlagGoesOnlyWhenAskedFor() = runBlocking<Unit> {
        val sender = sender()
        val file = File(dir, "shot.jpg").also { it.writeBytes(ByteArray(300) { b -> b.toByte() }) }

        sender.sendText(paired, "plain")
        sender.sendText(paired, "copy me", clip = true)
        sender.sendFiles(paired, listOf(Uri.fromFile(file)))
        sender.sendFiles(paired, listOf(Uri.fromFile(file)), clip = true)

        assertEquals(listOf(null, true, null, true), pc.items.map { it.clip })
        assertEquals(listOf(false, true, false, true), timeline.entries.value.reversed().map { it.clip })
    }

    @Test
    fun aShotOrPasteOlderThanFiveMinutesWhenItsPostStartsIsNotClipped() = runBlocking<Unit> {
        val sender = sender()
        val file = File(dir, "shot.jpg").also { it.writeBytes(ByteArray(300) { b -> b.toByte() }) }

        sender.sendText(paired, "fresh", clip = true, at = now - CLIP_MAX_AGE_MS)
        sender.sendText(paired, "stale", clip = true, at = now - CLIP_MAX_AGE_MS - 1)
        sender.sendFiles(paired, listOf(Uri.fromFile(file)), clip = true, at = now - CLIP_MAX_AGE_MS)
        sender.sendFiles(paired, listOf(Uri.fromFile(file)), clip = true, at = now - CLIP_MAX_AGE_MS - 1)

        assertEquals(listOf(true, null, true, null), pc.items.map { it.clip })
        assertEquals(listOf(true, false, true, false), timeline.entries.value.reversed().map { it.clip })
    }

    @Test
    fun aFileTheComputerRefusedStaysKeptAndCanBeSentAgain() = runBlocking<Unit> {
        val sender = sender()
        val content = ByteArray(300) { b -> b.toByte() }
        val shot = File(dir, "shot.jpg").also { it.writeBytes(content) }
        pc.chunkErrors += 500 to "serverError"

        sender.sendFiles(paired, listOf(Uri.fromFile(shot)), clip = true)
        shot.delete()

        val row = timeline.entries.value.single()
        assertEquals(EntryState.Failed, row.state)
        assertEquals(1, keptCopies().size)
        assertEquals(row.id, sender.outgoing.pending.single().id)

        sender.sendStaged(row.id)

        assertEquals(EntryState.Done, timeline.get(row.id)!!.state)
        assertTrue(content.contentEquals(pc.received.toByteArray()))
        assertTrue(sender.outgoing.pending.isEmpty())
        assertTrue(keptCopies().isEmpty())
    }

    @Test
    fun aKeptSendGoesOnAfterTheAppStartedAgain() = runBlocking<Unit> {
        val content = ByteArray(500) { b -> (b * 3).toByte() }
        val file = File(dir, "doc.pdf").also { it.writeBytes(content) }
        pc.chunkErrors += 500 to "serverError"
        sender().sendFiles(paired, listOf(Uri.fromFile(file)))
        file.delete()

        val restarted = sender()
        restarted.resumePending()

        assertEquals(EntryState.Done, timeline.entries.value.single().state)
        assertTrue(content.contentEquals(pc.received.toByteArray()))
        assertEquals(1, pc.items.map { it.sendId }.distinct().size)
        assertTrue(keptCopies().isEmpty())
    }

    @Test
    fun aFileThatCannotBeReadLeavesNothingToKeep() = runBlocking<Unit> {
        val sender = sender()

        sender.sendFiles(paired, listOf(Uri.parse("content://nothing/1")))

        assertEquals(EntryState.Failed, timeline.entries.value.single().state)
        assertTrue(sender.outgoing.pending.isEmpty())
        assertTrue(pc.items.isEmpty())
    }

    @Test
    fun aComputerThatForgotThePhoneIsRemovedWithAMessageAndTheLibraryRunStops() = runBlocking<Unit> {
        val asset = File(dir, "a.jpg").also { it.writeBytes(ByteArray(300)) }
        val forgetting = paired.copy(secret = "d3Jvbmctc2VjcmV0LXdyb25nLXNlY3JldC13cm9uZw")
        val sender = sender(Asset("external_primary:image:1:300:5", Uri.fromFile(asset), "a.jpg", 300, "image/jpeg", 0))
        store.put(forgetting)

        sender.syncGallery(forgetting)

        val entry = timeline.get("gallery-desktop-test-01")!!
        assertEquals(EntryState.Failed, entry.state)
        assertEquals("Test PC no longer knows this phone.", entry.detail)
        assertEquals(null, store.get(forgetting.id))
        assertEquals(0, pc.requests.count { it.startsWith("PUT") || it == "POST /v1/items" })
    }

    @Test
    fun aFileForAComputerThatForgotThePhoneFailsItsRowAndRemovesTheComputer() = runBlocking<Unit> {
        val forgetting = paired.copy(secret = "d3Jvbmctc2VjcmV0LXdyb25nLXNlY3JldC13cm9uZw")
        val sender = sender()
        store.put(forgetting)
        val file = File(dir, "x.txt").also { it.writeText("x") }

        sender.sendFiles(forgetting, listOf(Uri.fromFile(file)))

        assertEquals("Test PC no longer knows this phone.", timeline.entries.value.single().detail)
        assertEquals(null, store.get(forgetting.id))
        assertTrue(sender.outgoing.pending.isEmpty())
    }

    @Test
    fun aLibraryRowIsSentAgainToItsOwnComputer() {
        assertEquals("desktop-b", galleryPcOf(GALLERY_ROW + "desktop-b"))
        assertEquals("desktop-a", galleryPcOf(GALLERY_ROW + "desktop-a"))
    }

    @Test
    fun aNewPhotoOnAnOldRowNumberIsNotTakenForTheOldOne() {
        val first = libraryId("external_primary", "image", 7, 1000, 1_700_000_000)
        val reused = libraryId("external_primary", "image", 7, 2400, 1_700_050_000)

        assertTrue(first != reused)
        assertEquals(first, libraryId("external_primary", "image", 7, 1000, 1_700_000_000))
    }

    @Test
    fun aTextOverOneMegabyteIsTooLongAndOneUnderItIsNot() {
        assertTrue(noteTooLong("x".repeat(2 * 1024 * 1024)))
        assertTrue(!noteTooLong("x".repeat(1024 * 1024)))
    }

    @Test
    fun aGallerySyncNeverAsksForTheClipboard() = runBlocking<Unit> {
        val file = File(dir, "old.jpg").also { it.writeBytes(ByteArray(300)) }
        val asset = Asset("external_primary:image:7", Uri.fromFile(file), "old.jpg", 300, "image/jpeg", 0)

        sender(asset).syncGallery(paired)

        assertEquals(listOf<Boolean?>(null), pc.items.map { it.clip })
    }

    @Test
    fun anAssetThatCannotBeReadIsSkippedNotRetried() = runBlocking {
        val gone = Asset("external_primary:image:1", Uri.parse("content://nothing/1"), "gone.jpg", 10, "image/jpeg", 0)

        sender(gone).syncGallery(paired)

        val entry = timeline.get("gallery-desktop-test-01")!!
        assertEquals(EntryState.Done, entry.state)
        assertEquals("1 could not be sent", entry.detail)
        assertEquals(0, pc.requests.count { it.startsWith("PUT") })
        assertTrue(pc.requests.count { it == "GET /v1/hello" } <= 2)
    }
}
