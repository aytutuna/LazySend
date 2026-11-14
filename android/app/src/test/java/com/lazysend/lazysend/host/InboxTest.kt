package com.lazysend.lazysend.host

import com.lazysend.lazysend.link.ItemRequest
import com.lazysend.lazysend.transfer.MemFiles
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class InboxTest {
    private val dir = File.createTempFile("inbox", "").also { it.delete(); it.mkdirs() }
    private val files = MemFiles(0)
    private val index = GalleryIndex(File(dir, "index"))
    private var free = 100L * 1024 * 1024 * 1024
    private val inbox = newInbox()
    private val guest = Guest("phone-0001", "Pixel 8", "android", "1", "", 0, 0)

    private fun newInbox() = Inbox(File(dir, "incoming"), files, index, { free })

    private fun body(bytes: ByteArray) = RequestBody(ByteArrayInputStream(bytes), bytes.size.toLong())

    private fun sha(bytes: ByteArray) = hex(MessageDigest.getInstance("SHA-256").digest(bytes))

    private fun put(id: String, offset: Long, bytes: ByteArray) = inbox.write(guest.id, id, offset, bytes.size.toLong(), body(bytes)) {}

    private fun expect(status: Int, code: String, block: () -> Unit): HostError {
        try {
            block()
        } catch (e: HostError) {
            assertEquals(code, e.code)
            assertEquals(status, e.status)
            return e
        }
        fail("expected $code")
        throw AssertionError()
    }

    @Test
    fun aFileComesInChunksAndLandsInTheGuestsFolder() {
        val data = ByteArray(10_000) { (it % 251).toByte() }
        val begun = inbox.begin(guest, ItemRequest("file", name = "a/b.bin", size = 10_000, sha256 = sha(data), mime = "application/octet-stream"))
        assertFalse(begun.done)
        assertEquals(0L, begun.offset)
        assertEquals(4000L, put(begun.id, 0, data.copyOfRange(0, 4000)).offset)
        assertEquals(4000L, inbox.state(guest.id, begun.id)!!.offset)
        val last = put(begun.id, 4000, data.copyOfRange(4000, 10_000))
        assertTrue(last.done)
        val uri = files.data.keys.single()
        assertArrayEquals(data, files.bytes(uri))
        assertEquals("a_b.bin", files.names[uri])
        assertEquals("Pixel 8", files.folders[uri])
        assertTrue(put(begun.id, 4000, data.copyOfRange(4000, 10_000)).done)
    }

    @Test
    fun aWrongOffsetAnswersTheCurrentLengthAndDropsTheBody() {
        val begun = inbox.begin(guest, ItemRequest("file", name = "a", size = 100))
        put(begun.id, 0, ByteArray(40))
        val b = body(ByteArray(10))
        val e = expect(409, "offsetMismatch") { inbox.write(guest.id, begun.id, 0, 10, b) {} }
        assertEquals(40L, e.offset)
        assertEquals(0L, b.remaining)
        expect(400, "badRequest") { put(begun.id, 40, ByteArray(61)) }
        expect(400, "badRequest") { put(begun.id, 101, ByteArray(0)) }
        expect(404, "notFound") { inbox.write("phone-0002", begun.id, 40, 1, body(ByteArray(1))) {} }
    }

    @Test
    fun anEmptyFileIsDoneAtOnce() {
        val begun = inbox.begin(guest, ItemRequest("file", name = "empty.txt", size = 0))
        assertTrue(begun.done)
        assertEquals(1, files.finished.size)
        assertTrue(files.bytes(files.data.keys.single()).isEmpty())
    }

    @Test
    fun anEmptyChunkFinishesAFullPartThatWasNeverPutInPlace() {
        val begun = inbox.begin(guest, ItemRequest("file", name = "a", size = 5))
        val uri = files.data.keys.single()
        files.append(files.existing(uri)!!).use { it.write(ByteArray(5)) }
        assertTrue(inbox.write(guest.id, begun.id, 5, 0, body(ByteArray(0))) {}.done)
        assertEquals(1, files.finished.size)
    }

    @Test
    fun aWrongHashDeletesTheFile() {
        val data = ByteArray(50)
        val begun = inbox.begin(guest, ItemRequest("file", name = "a", size = 50, sha256 = "0".repeat(64)))
        expect(422, "hashMismatch") { put(begun.id, 0, data) }
        assertTrue(files.data.isEmpty())
        assertNull(inbox.state(guest.id, begun.id))
    }

    @Test
    fun theHashSurvivesAResumeAcrossRestartByReadingTheFileOnce() {
        val data = ByteArray(300) { it.toByte() }
        val begun = inbox.begin(guest, ItemRequest("file", name = "a", size = 300, sha256 = sha(data)))
        put(begun.id, 0, data.copyOfRange(0, 100))
        val restarted = newInbox()
        assertEquals(100L, restarted.state(guest.id, begun.id)!!.offset)
        assertTrue(restarted.write(guest.id, begun.id, 100, 200, body(data.copyOfRange(100, 300))) {}.done)
    }

    @Test
    fun aFullPartIsFinishedAtStart() {
        val begun = inbox.begin(guest, ItemRequest("file", name = "a", size = 5))
        files.append(files.existing(files.data.keys.single())!!).use { it.write(ByteArray(5)) }
        newInbox()
        assertEquals(1, files.finished.size)
        assertTrue(newInbox().state(guest.id, begun.id)!!.done)
    }

    @Test
    fun aGalleryFileGoesIntoItsMonthAndIsReceivedOnce() {
        val request = ItemRequest("file", name = "IMG.jpg", size = 3, sourceId = "external:image:7", modified = "2026-03-09T12:00:00Z")
        val begun = inbox.begin(guest, request)
        assertEquals("Pixel 8/Gallery/2026-03", files.folders[files.data.keys.single()])
        assertEquals(begun.id, inbox.begin(guest, request).id)
        assertEquals(1, files.created.get())
        assertEquals(listOf("external:image:7"), index.missing(guest.id, listOf("external:image:7")))
        assertTrue(put(begun.id, 0, ByteArray(3)).done)
        assertEquals(java.time.Instant.parse("2026-03-09T12:00:00Z").toEpochMilli(), files.finished.values.single())
        val again = inbox.begin(guest, request)
        assertTrue(again.done)
        assertEquals(true, again.duplicate)
        assertEquals("", again.id)
        assertEquals(emptyList<String>(), index.missing(guest.id, listOf("external:image:7")))
        assertEquals(listOf("x"), index.missing("phone-0002", listOf("x", "x")))
    }

    @Test
    fun aSameSourceIdWithAnotherSizeStartsAgain() {
        val first = inbox.begin(guest, ItemRequest("file", name = "a", size = 3, sourceId = "s1"))
        val second = inbox.begin(guest, ItemRequest("file", name = "a", size = 4, sourceId = "s1"))
        assertNotEquals(first.id, second.id)
    }

    @Test
    fun implausibleDatesAreIgnored() {
        inbox.begin(guest, ItemRequest("file", name = "old", size = 3, sourceId = "s1", modified = "1970-01-01T00:00:00Z"))
        val folder = files.folders[files.data.keys.single()]!!
        assertTrue(folder, folder.startsWith("Pixel 8/Gallery/20"))
        assertNull(files.finished.values.firstOrNull())
    }

    @Test
    fun aFileThatWouldLeaveUnderAGigabyteFreeIsRefused() {
        free = MIN_FREE_BYTES + 99
        expect(507, "diskFull") { inbox.begin(guest, ItemRequest("file", name = "a", size = 100)) }
        val begun = inbox.begin(guest, ItemRequest("file", name = "a", size = 99))
        free = MIN_FREE_BYTES + 5
        expect(507, "diskFull") { put(begun.id, 0, ByteArray(10)) }
        assertEquals(0L, inbox.state(guest.id, begun.id)!!.offset)
    }

    @Test
    fun badRequestsAreRefused() {
        expect(400, "badRequest") { inbox.begin(guest, ItemRequest("file", name = "a")) }
        expect(400, "badRequest") { inbox.begin(guest, ItemRequest("file", name = "a", size = -1)) }
        expect(400, "badRequest") { inbox.begin(guest, ItemRequest("file", name = "a", size = 1, sha256 = "xyz")) }
        expect(400, "badRequest") { inbox.begin(guest, ItemRequest("file", name = "a", size = 1, sourceId = "a\u0007b")) }
    }

    @Test
    fun aNewerRequestTakesOverFromOneStillOpen() {
        val begun = inbox.begin(guest, ItemRequest("file", name = "a", size = 100))
        val pipe = PipedOutputStream()
        val slow = RequestBody(PipedInputStream(pipe), 60)
        val aborted = CountDownLatch(1)
        val failure = arrayOfNulls<Throwable>(1)
        val older = thread {
            try {
                inbox.write(guest.id, begun.id, 0, 60, slow) { pipe.close(); aborted.countDown() }
            } catch (e: Throwable) {
                failure[0] = e
            }
        }
        pipe.write(ByteArray(20))
        pipe.flush()
        Thread.sleep(200)
        val state = inbox.write(guest.id, begun.id, 20, 80, body(ByteArray(80)) , {})
        assertTrue(aborted.await(5, TimeUnit.SECONDS))
        older.join(5000)
        assertTrue(failure[0] is IOException)
        assertTrue(state.done)
        assertEquals(100, files.bytes(files.data.keys.single()).size)
    }

    @Test
    fun removingAGuestDropsItsUnfinishedFilesButKeepsReceivedOnes() {
        val done = inbox.begin(guest, ItemRequest("file", name = "done", size = 2))
        put(done.id, 0, ByteArray(2))
        val partial = inbox.begin(guest, ItemRequest("file", name = "part", size = 9))
        inbox.removeDevice(guest.id)
        assertNull(inbox.state(guest.id, partial.id))
        assertNull(inbox.state(guest.id, done.id))
        assertEquals(1, files.data.size)
    }

}
