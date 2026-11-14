package com.lazysend.lazysend.host

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class OutboxTest {
    private val dir = File.createTempFile("outbox", "").also { it.delete(); it.mkdirs() }
    private val outbox = Outbox(File(dir, "outbox.json"), File(dir, "outgoing"))

    @Test
    fun aFileIsCopiedAndTheCopyGoesWhenItIsAcknowledged() {
        val item = outbox.queueFile("phone-0001", "a/b.txt", "text/plain") { ByteArrayInputStream("hello".toByteArray()) }
        assertEquals("a_b.txt", item.name)
        assertEquals(5L, item.size)
        assertEquals("hello", File(item.path!!).readText())
        assertNull(outbox.find("phone-0002", item.id))
        assertNotNull(outbox.acknowledge("phone-0001", item.id))
        assertFalse(File(item.path!!).exists())
        assertNull(outbox.acknowledge("phone-0001", item.id))
    }

    @Test
    fun aFileThatCannotBeReadLeavesNoCopyAndNoItem() {
        try {
            outbox.queueFile("phone-0001", "a", null) { throw IOException("gone") }
            fail()
        } catch (e: IOException) {
        }
        assertEquals(0, outbox.pending("phone-0001").size)
        assertEquals(0, File(dir, "outgoing").listFiles()?.size ?: 0)
    }

    @Test
    fun itemsSurviveARestartInOrder() {
        val text = outbox.queueText("phone-0001", "one")
        val link = outbox.queueLink("phone-0001", "https://alazy.app/send/")
        val again = Outbox(File(dir, "outbox.json"), File(dir, "outgoing"))
        assertEquals(listOf(text.id, link.id), again.pending("phone-0001").map { it.id })
    }

    @Test
    fun onlyHttpAndHttpsLinksAndNonEmptyTextAreQueued() {
        for (url in listOf("javascript:alert(1)", "ftp://x.y/z", "https://", "not a url", "")) {
            try {
                outbox.queueLink("phone-0001", url)
                fail(url)
            } catch (e: IllegalArgumentException) {
            }
        }
        try {
            outbox.queueText("phone-0001", "")
            fail()
        } catch (e: IllegalArgumentException) {
        }
    }

    @Test
    fun aWaitingGuestIsWokenWhenSomethingIsQueued() = runBlocking {
        val waiting = async { outbox.await("phone-0001", 5000) }
        delay(100)
        outbox.queueText("phone-0002", "for someone else")
        outbox.queueText("phone-0001", "mine")
        assertEquals(listOf("mine"), waiting.await().map { it.text })
    }

    @Test
    fun anEmptyWaitEndsWithNothingWhenTheTimeIsUp() = runBlocking {
        assertTrue(outbox.await("phone-0001", 100).isEmpty())
    }

    @Test
    fun clearingAGuestDropsItsItemsAndCopies() {
        val file = outbox.queueFile("phone-0001", "a", null) { ByteArrayInputStream(ByteArray(3)) }
        outbox.queueText("phone-0002", "keep")
        outbox.clear("phone-0001")
        assertFalse(File(file.path!!).exists())
        assertEquals(0, outbox.pending("phone-0001").size)
        assertEquals(1, outbox.pending("phone-0002").size)
    }

    @Test
    fun aThousandItemsAtMostWaitForOneGuest() {
        repeat(MAX_QUEUED) { outbox.queueText("phone-0001", "n$it") }
        try {
            outbox.queueText("phone-0001", "one more")
            fail()
        } catch (e: IllegalStateException) {
        }
        try {
            outbox.queueFile("phone-0001", "a", null) { ByteArrayInputStream(ByteArray(1)) }
            fail()
        } catch (e: IllegalStateException) {
        }
        assertEquals(0, File(dir, "outgoing").listFiles()?.size ?: 0)
    }

    @Test
    fun aFileIsNotCopiedWhenItWouldLeaveUnderAGigabyteFree() {
        var free = MIN_FREE_BYTES + 100
        val tight = Outbox(File(dir, "tight.json"), File(dir, "tight"), freeSpace = { free })
        var opened = false
        try {
            tight.queueFile("phone-0001", "big", null, 101) { opened = true; ByteArrayInputStream(ByteArray(1)) }
            fail()
        } catch (e: IllegalStateException) {
        }
        assertFalse(opened)
        assertEquals(0, tight.pending("phone-0001").size)
        assertNotNull(tight.queueFile("phone-0001", "small", null, 100) { ByteArrayInputStream(ByteArray(1)) })
    }
}
