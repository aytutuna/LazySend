package com.lazysend.lazysend.transfer

import com.lazysend.lazysend.data.Direction
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.EntryState
import com.lazysend.lazysend.data.Pc
import com.lazysend.lazysend.data.PcStore
import com.lazysend.lazysend.data.Timeline
import com.lazysend.lazysend.data.TimelineEntry
import com.lazysend.lazysend.link.FakePc
import com.lazysend.lazysend.link.OutboxEntry
import com.lazysend.lazysend.link.TEST_SECRET
import com.lazysend.lazysend.link.encodeBase64Url
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReceiverTest {
    private val pc = FakePc()
    private val dir = File.createTempFile("receiver", "").also { it.delete(); it.mkdirs() }
    private val store = PcStore(File(dir, "pcs.json"), { it }, { it })
    private val timeline = Timeline(File(dir, "timeline.json"))
    private val files = MemFiles()
    private val paired = Pc("desktop-test-01", "Test PC", encodeBase64Url(pc.pin), listOf(pc.endpoint.host), pc.endpoint.port, TEST_SECRET)
    private val receiver = Receiver(PcConnector(store, null), timeline, files, { _, _, _ -> })

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
