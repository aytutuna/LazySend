package com.lazysend.lazysend.link

import java.io.ByteArrayInputStream
import java.io.IOException
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkClientTest {
    private val pc = FakePc()

    @After
    fun stop() = pc.close()

    private suspend inline fun <reified E : Throwable> failure(block: () -> Unit): E {
        try {
            block()
        } catch (e: Throwable) {
            if (e is E) return e
            throw e
        }
        fail("expected ${E::class.simpleName}")
        error("unreachable")
    }

    private fun bytes(size: Int) = ByteArray(size) { (it * 31 + 7).toByte() }

    private fun source(data: ByteArray) = DataSource { offset -> ByteArrayInputStream(data, offset.toInt(), data.size - offset.toInt()) }

    private fun fileRequest(data: ByteArray, sourceId: String? = null) =
        ItemRequest("file", name = "a.bin", size = data.size.toLong(), sourceId = sourceId, sha256 = sha256Hex(source(data)))

    private fun uploader(chunk: Long = 4096) = Uploader({ pc.client() }, chunk, List(4) { 0L })

    @Test
    fun pinnedCertificateIsTrusted() = runTest {
        val hello = pc.client().hello()
        assertEquals("Test PC", hello.desktopName)
        assertEquals(listOf("192.168.42.10"), hello.addresses)
    }

    @Test
    fun otherKeyIsRefused() = runTest {
        val wrong = pc.pin.copyOf().also { it[0] = (it[0] + 1).toByte() }
        failure<IOException> { pc.client(pin = wrong).hello() }
        assertTrue(pc.requests.isEmpty())
    }

    @Test
    fun pairingReturnsTheSecret() = runTest {
        val reply = pc.client(credentials = null).pair(TEST_TOKEN, TEST_DEVICE, "Pixel", "1.0.0")
        assertEquals(TEST_SECRET, reply.deviceSecret)
        assertEquals("desktop-test-01", reply.desktopId)
    }

    @Test
    fun pairingErrorsKeepTheirCode() = runTest {
        val e = failure<LinkException> { pc.client(credentials = null).pair("bad", TEST_DEVICE, "Pixel", "1.0.0") }
        assertEquals("tokenInvalid", e.code)
        assertEquals(403, e.status)
    }

    @Test
    fun wrongSecretIsUnauthorized() = runTest {
        val e = failure<LinkException> { pc.client(credentials = Credentials(TEST_DEVICE, "nope")).hello() }
        assertEquals("unauthorized", e.code)
    }

    @Test
    fun textAndLinksGoAsItems() = runTest {
        val client = pc.client()
        assertTrue(client.postItem(ItemRequest("text", text = "hello there")).done)
        assertTrue(client.postItem(ItemRequest("link", url = "https://example.com/a")).done)
        assertEquals(listOf("hello there", "https://example.com/a"), pc.texts)
    }

    @Test
    fun fileGoesUpInChunks() = runTest {
        val data = bytes(10_000)
        val seen = mutableListOf<Long>()
        uploader().sendFile(fileRequest(data), source(data)) { seen += it }
        assertArrayEquals(data, pc.received.toByteArray())
        assertEquals(listOf(0L, 4096L, 8192L, 10_000L), seen)
        assertEquals(3, pc.requests.count { it.startsWith("PUT") })
    }

    @Test
    fun emptyFileNeedsNoChunks() = runTest {
        uploader().sendFile(fileRequest(ByteArray(0)), source(ByteArray(0)))
        assertEquals(0, pc.requests.count { it.startsWith("PUT") })
    }

    @Test
    fun resumesFromWhereThePcSaysAfterAMidChunkDrop() = runTest {
        val data = bytes(10_000)
        var opens = 0
        // The second chunk's stream breaks after 1000 bytes, as a dropped connection does; the PC keeps none of that chunk.
        val flaky = DataSource { offset ->
            val stream = ByteArrayInputStream(data, offset.toInt(), data.size - offset.toInt())
            if (++opens != 2) stream else object : java.io.InputStream() {
                var left = 1000
                override fun read(): Int = error("unused")
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    if (left == 0) throw IOException("connection reset")
                    val n = stream.read(b, off, minOf(len, left))
                    left -= n
                    return n
                }
            }
        }
        uploader().sendFile(fileRequest(data), flaky)
        assertArrayEquals(data, pc.received.toByteArray())
        assertTrue(pc.requests.contains("GET /v1/items/item00000001"))
    }

    @Test
    fun doesNotResendAChunkWhoseAnswerWasLost() = runTest {
        val data = bytes(10_000)
        pc.chunkDrops += listOf(FakePc.Drop.None, FakePc.Drop.AnswerLost)
        uploader().sendFile(fileRequest(data), source(data))
        assertArrayEquals(data, pc.received.toByteArray())
        assertEquals(3, pc.requests.count { it.startsWith("PUT") })
    }

    @Test
    fun takesTheOffsetFromAMismatchAnswer() = runTest {
        val data = bytes(10_000)
        pc.received.write(data, 0, 4096)
        val seen = mutableListOf<Long>()
        // The PC already holds the first chunk although the begin answer said 0 once; its 409 gives the offset.
        val request = fileRequest(data)
        pc.client().postItem(request)
        val client = Uploader({ pc.client() }, 4096, listOf(0))
        client.sendFile(request, source(data)) { seen += it }
        assertArrayEquals(data, pc.received.toByteArray())
        assertEquals(4096L, seen.first())
    }

    @Test
    fun givesUpAfterTheRetries() = runTest {
        val data = bytes(100)
        val dead = Uploader({ FakePc().also { it.close() }.client() }, 4096, listOf(0, 0))
        failure<IOException> { dead.sendFile(fileRequest(data), source(data)) }
    }

    @Test
    fun startsOverAfterAHashMismatch() = runTest {
        val data = bytes(5000)
        val wrong = fileRequest(data).copy(sha256 = "0".repeat(64))
        val e = failure<LinkException> { uploader().sendFile(wrong, source(data)) }
        assertEquals("hashMismatch", e.code)
        assertEquals(2, pc.requests.count { it == "POST /v1/items" })
    }

    @Test
    fun duplicateAssetIsNotSentAgain() = runTest {
        pc.have += "asset-1"
        val data = bytes(100)
        val result = uploader().sendFile(fileRequest(data, "asset-1"), source(data))
        assertTrue(result.duplicate)
        assertEquals(0, pc.requests.count { it.startsWith("PUT") })
    }

    @Test
    fun galleryCheckGoesInBatchesOfAThousand() = runTest {
        val ids = (1..2500).map { "asset-$it" }
        pc.have += ids.take(300)
        val missing = pc.client().missingIds(ids)
        assertEquals(listOf(1000, 1000, 500), pc.galleryBatches)
        assertEquals(ids.drop(300), missing)
    }

    @Test
    fun outboxItemsDownloadWithRangeAndAreAcknowledged() = runTest {
        pc.outboxFile = bytes(10_000)
        pc.outbox += OutboxEntry("out1", "file", name = "x.bin", size = 10_000)
        pc.outbox += OutboxEntry("out2", "text", text = "from the pc")
        val client = pc.client()

        val reply = client.outbox(0)
        assertEquals(listOf("out1", "out2"), reply.items.map { it.id })

        val first = client.download("out1", 0)
        assertEquals(200, first.status)
        val head = first.body.readNBytes(3000)
        first.close()
        val rest = client.download("out1", 3000)
        assertEquals(206, rest.status)
        assertEquals(10_000L, rest.size)
        val tail = rest.body.readAllBytes()
        rest.close()
        assertArrayEquals(pc.outboxFile, head + tail)

        client.acknowledge("out1")
        client.acknowledge("out2")
        assertEquals(listOf("out1", "out2"), pc.acknowledged)
        assertFalse(client.outbox(0).items.isNotEmpty())
    }
}
