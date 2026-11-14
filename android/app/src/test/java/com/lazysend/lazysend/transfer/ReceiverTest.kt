package com.lazysend.lazysend.transfer

import com.lazysend.lazysend.data.Direction
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.EntryState
import com.lazysend.lazysend.data.Pc
import com.lazysend.lazysend.data.PcStore
import com.lazysend.lazysend.data.Timeline
import com.lazysend.lazysend.data.TimelineEntry
import com.lazysend.lazysend.host.GalleryIndex
import com.lazysend.lazysend.host.MONTH
import com.lazysend.lazysend.link.FakePc
import com.lazysend.lazysend.link.OutboxEntry
import com.lazysend.lazysend.link.TEST_SECRET
import com.lazysend.lazysend.link.encodeBase64Url
import java.io.File
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

private class FullFiles(inner: ReceivedFiles) : ReceivedFiles by inner {
    override fun append(part: ReceivedFiles.Part): java.io.OutputStream = throw java.io.IOException("write failed: ENOSPC (No space left on device)")
}

class ReceiverTest {
    private val pc = FakePc()
    private val dir = File.createTempFile("receiver", "").also { it.delete(); it.mkdirs() }
    private val store = PcStore(File(dir, "pcs.json"), { it }, { it })
    private val timeline = Timeline(File(dir, "timeline.json"))
    private val files = MemFiles()
    private val paired = Pc("desktop-test-01", "Test PC", encodeBase64Url(pc.pin), listOf(pc.endpoint.host), pc.endpoint.port, TEST_SECRET)
    private val index = GalleryIndex(File(dir, "guest-index"))
    private val partsFile = File(dir, "gallery-parts.json")
    private val receiver = Receiver(PcConnector(store, null), timeline, files, index, GalleryParts(partsFile), { _, _, _ -> })

    @After
    fun stop() {
        pc.close()
        dir.deleteRecursively()
    }

    private fun bytes(size: Int) = ByteArray(size) { (it * 7).toByte() }

    private fun partial(itemId: String, part: ReceivedFiles.Part, total: Long) = timeline.add(
        TimelineEntry("in-$itemId", 0, Direction.Received, EntryKind.File, "Test PC", "x.bin", state = EntryState.Paused, bytes = part.size, totalBytes = total, uri = part.uri),
    )

    @Test
    fun downloadsAFileAndAcknowledgesIt() = runBlocking {
        pc.outboxFile = bytes(10_000)
        pc.outbox += OutboxEntry("out1", "file", name = "x.bin", size = 10_000)

        receiver.collect(paired, pc.client(), 0)

        assertEquals(EntryState.Done, timeline.get("in-out1")!!.state)
        assertArrayEquals(pc.outboxFile, files.data["mem://1"]!!.toByteArray())
        assertEquals(listOf("out1"), pc.acknowledged)
    }

    @Test
    fun aRefusedRangeFailsTheItemAndTheQueueMovesOn() = runBlocking {
        // The PC's file is shorter than the part already saved, so asking to continue is refused with 416.
        pc.outboxFile = bytes(2_000)
        pc.outbox += OutboxEntry("out1", "file", name = "x.bin", size = 5_000)
        pc.outbox += OutboxEntry("out2", "text", text = "after it")
        partial("out1", files.seed(3_000), 5_000)

        receiver.collect(paired, pc.client(), 0)

        assertEquals(EntryState.Failed, timeline.get("in-out1")!!.state)
        assertEquals(EntryState.Done, timeline.get("in-out2")!!.state)
        assertEquals(listOf("out1", "out2"), pc.acknowledged)
    }

    @Test
    fun aCompletePartIsPutInPlaceWithoutDownloading() = runBlocking {
        pc.outbox += OutboxEntry("out1", "file", name = "x.bin", size = 4_000)
        partial("out1", files.seed(4_000), 4_000)

        receiver.collect(paired, pc.client(), 0)

        assertEquals(EntryState.Done, timeline.get("in-out1")!!.state)
        assertTrue(pc.requests.none { it.endsWith("/data") })
        assertEquals(listOf("out1"), pc.acknowledged)
    }

    @Test
    fun aGalleryFileIsFiledByTheMonthItWasTakenAndCountedInOneRow() = runBlocking {
        pc.outboxFile = bytes(5_000)
        pc.outbox += OutboxEntry("out1", "file", name = "IMG_1.jpg", size = 5_000, mime = "image/jpeg", sourceId = "local:image:1", taken = "2021-03-15T12:00:00Z")
        pc.outbox += OutboxEntry("out2", "file", name = "IMG_2.jpg", size = 5_000, mime = "image/jpeg", sourceId = "local:image:2", taken = "2021-03-16T12:00:00Z")

        receiver.collect(paired, pc.client(), 0)

        val month = MONTH.format(Instant.ofEpochMilli(1_615_809_600_000))
        assertEquals("Test PC/Gallery/$month", files.folders["mem://1"])
        assertEquals(1_615_809_600_000, files.finished["mem://1"])
        assertArrayEquals(pc.outboxFile, files.data["mem://1"]!!.toByteArray())
        assertNull(timeline.get("in-out1"))
        val row = timeline.get("gallery-from-desktop-test-01")!!
        assertEquals(EntryKind.Gallery, row.kind)
        assertEquals(2, row.count)
        assertEquals(listOf("out1", "out2"), pc.acknowledged)
    }

    @Test
    fun aGalleryFileWithoutADateIsFiledByTheMonthItArrived() = runBlocking {
        pc.outboxFile = bytes(100)
        pc.outbox += OutboxEntry("out1", "file", name = "clip.mp4", size = 100, mime = "video/mp4", sourceId = "local:video:7")

        receiver.collect(paired, pc.client(), 0)

        assertEquals("Test PC/Gallery/${MONTH.format(Instant.now())}", files.folders["mem://1"])
        assertNull(files.finished["mem://1"])
        assertEquals(listOf("out1"), pc.acknowledged)
    }

    @Test
    fun aGalleryFileListedAgainIsOnlyAcknowledged() = runBlocking {
        pc.outboxFile = bytes(100)
        pc.outbox += OutboxEntry("out1", "file", name = "IMG_1.jpg", size = 100, mime = "image/jpeg", sourceId = "local:image:1")
        receiver.collect(paired, pc.client(), 0)
        pc.outbox += OutboxEntry("out1", "file", name = "IMG_1.jpg", size = 100, mime = "image/jpeg", sourceId = "local:image:1")

        receiver.collect(paired, pc.client(), 0)

        assertEquals(1, files.created.get())
        assertEquals(listOf("out1", "out1"), pc.acknowledged)
        assertEquals(1, timeline.get("gallery-from-desktop-test-01")!!.count)
    }

    @Test
    fun aGalleryAssetReceivedBeforeIsOnlyAcknowledgedAndForgottenWithItsPc() = runBlocking {
        pc.outboxFile = bytes(100)
        pc.outbox += OutboxEntry("out1", "file", name = "IMG_1.jpg", size = 100, mime = "image/jpeg", sourceId = "local:image:1")
        receiver.collect(paired, pc.client(), 0)
        pc.outbox += OutboxEntry("out9", "file", name = "IMG_1.jpg", size = 100, mime = "image/jpeg", sourceId = "local:image:1")

        receiver.collect(paired, pc.client(), 0)

        assertEquals(1, files.created.get())
        assertEquals(listOf("out1", "out9"), pc.acknowledged)
        receiver.forget(paired.id)
        assertTrue(!index.contains(paired.id, "local:image:1"))
    }

    @Test
    fun aGalleryPartLeftByADeadProcessCarriesOnFromItsSize() = runBlocking {
        pc.outboxFile = bytes(5_000)
        pc.outbox += OutboxEntry("out1", "file", name = "IMG_1.jpg", size = 5_000, mime = "image/jpeg", sourceId = "local:image:1")
        val left = files.seed(3_000)
        GalleryParts(partsFile).put("${paired.id}/out1", left.uri)

        Receiver(PcConnector(store, null), timeline, files, index, GalleryParts(partsFile), { _, _, _ -> }).collect(paired, pc.client(), 0)

        assertEquals(1, files.created.get())
        val data = files.bytes(left.uri)
        assertEquals(5_000, data.size)
        assertArrayEquals(ByteArray(3_000), data.copyOfRange(0, 3_000))
        assertArrayEquals(pc.outboxFile.copyOfRange(3_000, 5_000), data.copyOfRange(3_000, 5_000))
    }

    @Test
    fun aNameThatClimbsOutOfTheFolderIsMadeSafe() = runBlocking {
        pc.outboxFile = bytes(10)
        pc.outbox += OutboxEntry("out1", "file", name = "../../evil.bin", size = 10)

        receiver.collect(paired, pc.client(), 0)

        assertEquals("_.._evil.bin", files.names["mem://1"])
    }

    @Test
    fun aFullDiskLeavesTheItemQueuedAndTellsTheUserOnce() = runBlocking {
        val told = mutableListOf<String>()
        val full = Receiver(PcConnector(store, null), timeline, FullFiles(files), index, GalleryParts(partsFile), { _, _, text -> told += text })
        pc.outboxFile = bytes(1_000)
        pc.outbox += OutboxEntry("out1", "file", name = "x.bin", size = 1_000)
        pc.outbox += OutboxEntry("out2", "file", name = "IMG.jpg", size = 1_000, mime = "image/jpeg", sourceId = "local:image:3")

        repeat(2) {
            try {
                full.collect(paired, pc.client(), 0)
                fail("Expected the storage to be full")
            } catch (e: StorageFullException) {
            }
        }

        assertEquals(emptyList<String>(), pc.acknowledged)
        assertEquals(1, told.size)
        assertTrue(timeline.entries.value.none { it.state == EntryState.Failed })
    }

    @Test
    fun twoCollectsDoNotDownloadTheSameItemTwice() = runBlocking {
        pc.outboxFile = bytes(300_000)
        pc.outbox += OutboxEntry("out1", "file", name = "x.bin", size = 300_000)

        listOf(
            async(Dispatchers.IO) { receiver.collect(paired, pc.client(), 0) },
            async(Dispatchers.IO) { receiver.collect(paired, pc.client(), 0) },
        ).awaitAll()

        assertEquals(1, files.created.get())
        assertArrayEquals(pc.outboxFile, files.data["mem://1"]!!.toByteArray())
    }
}
