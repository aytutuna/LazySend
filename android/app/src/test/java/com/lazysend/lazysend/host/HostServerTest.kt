package com.lazysend.lazysend.host

import com.lazysend.lazysend.link.DataSource
import com.lazysend.lazysend.link.ItemRequest
import com.lazysend.lazysend.link.LinkException
import com.lazysend.lazysend.link.Uploader
import com.lazysend.lazysend.link.missingIds
import com.lazysend.lazysend.link.sha256Hex
import java.io.ByteArrayInputStream
import java.io.IOException
import java.net.InetAddress
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class HostServerTest {
    private val host = HostFixture()
    private val texts = CopyOnWriteArrayList<Triple<String, String, String>>()

    init {
        host.core.router.onText = { guest, kind, text -> texts.add(Triple(guest.name, kind, text)) }
    }

    @After
    fun stop() = host.close()

    private fun source(bytes: ByteArray) = DataSource { offset -> ByteArrayInputStream(bytes, offset.toInt(), bytes.size - offset.toInt()) }

    private fun refused(code: String, block: suspend () -> Unit): LinkException {
        try {
            runBlocking { block() }
        } catch (e: LinkException) {
            assertEquals(code, e.code)
            return e
        }
        fail("expected $code")
        throw AssertionError()
    }

    @Test
    fun pairingByQrShowsTheCheckCodeAndTheGuestKeepsTheSecret() = runBlocking<Unit> {
        val session = host.core.openPairing()
        val seen = async { host.core.approval.filterNotNull().first() }
        val reply = async { host.client().pair(session.tokenText, "phone-test-0001", "Pixel 9", "1.0") }
        val question = seen.await()
        assertEquals(Fingerprint.spaced(Fingerprint.checkCode(host.identity.fingerprint)), question.digits)
        assertEquals("Pixel 9", question.guestName)
        question.respond(true)
        val paired = reply.await()
        assertEquals("host-test-0001", paired.desktopId)
        assertEquals("Pixel host", paired.desktopName)
        val credentials = com.lazysend.lazysend.link.Credentials("phone-test-0001", paired.deviceSecret)
        assertTrue(host.client(credentials).health().paired)
        assertFalse(host.client().health().paired)
        assertFalse(host.dir.walkTopDown().filter { it.isFile }.any { it.readText().contains(paired.deviceSecret) })
        refused("pairingClosed") { host.client().pair(session.tokenText, "phone-test-0002", "x", "1") }
    }

    @Test
    fun pairingByShortCodeShowsTheMatchDigitsInAnyCase() = runBlocking<Unit> {
        val session = host.core.openPairing()
        val seen = async { host.core.approval.filterNotNull().first() }
        val reply = async { host.client().pair(session.shortCodeText.lowercase().replace("-", " "), "phone-test-0001", "Pixel", "1.0") }
        val question = seen.await()
        assertEquals(Fingerprint.spaced(Fingerprint.matchCode(host.identity.fingerprint, session.shortCode)), question.digits)
        question.respond(true)
        assertEquals("host-test-0001", reply.await().desktopId)
    }

    @Test
    fun declinedAndUnansweredPairingsAreRefused() {
        refused("declined") { host.pair(allow = false) }
        host.core.router.approvalTimeoutMs = 300
        refused("declined") {
            host.core.openPairing().let { host.client().pair(it.tokenText, "phone-test-0001", "x", "1") }
        }
        assertNull(host.core.approval.value)
        assertTrue(host.core.guests.guests.value.isEmpty())
    }

    @Test
    fun theGuestHangingUpWhileTheQuestionIsOpenClearsIt() = runBlocking<Unit> {
        val session = host.core.openPairing()
        val call = async { runCatching { host.client().pair(session.tokenText, "phone-test-0001", "x", "1") } }
        val question = host.core.approval.filterNotNull().first()
        call.cancel()
        withTimeout(5000) { while (host.core.approval.value != null) delay(20) }
        question.respond(true)
        assertTrue(host.core.guests.guests.value.isEmpty())
    }

    @Test
    fun theHostRefusesAPairingWhenNoneIsOpen() {
        refused("pairingClosed") { host.client().pair("AAAAAAAAAAAAAAAAAAAAAA", "phone-test-0001", "x", "1") }
    }

    @Test
    fun fiveWrongTokensRefuseThatAddressForTheSession() {
        val session = host.core.openPairing()
        repeat(5) { refused("tokenInvalid") { host.client().pair("7KQ2M9XD", "phone-test-0001", "x", "1") } }
        refused("pairingClosed") { host.client().pair(session.tokenText, "phone-test-0001", "x", "1") }
    }

    @Test
    fun tenWrongSecretsBlockTheAddressBeforeTls() {
        val bad = host.client(com.lazysend.lazysend.link.Credentials("phone-test-0001", "c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0LXNlY3JldA"))
        repeat(10) { refused("unauthorized") { bad.hello() } }
        try {
            runBlocking { bad.hello() }
            fail()
        } catch (e: IOException) {
        }
    }

    @Test
    fun theSeventeenthGuestIsRefused() {
        repeat(16) { host.pair("phone-test-%04d".format(it)) }
        refused("tooManyDevices") { host.pair("phone-test-9999") }
        host.pair("phone-test-0003")
        assertEquals(16, host.core.guests.guests.value.size)
    }

    @Test
    fun textAndLinksArriveAndOtherSchemesAreRefused() {
        val client = host.client(host.pair())
        runBlocking {
            assertTrue(client.postItem(ItemRequest("text", text = "hello")).done)
            assertTrue(client.postItem(ItemRequest("link", url = "https://alazy.app/send/")).done)
        }
        assertEquals(listOf("hello", "https://alazy.app/send/"), texts.map { it.third })
        assertEquals("Test phone", texts.first().first)
        refused("badRequest") { client.postItem(ItemRequest("link", url = "javascript:alert(1)")) }
        refused("badRequest") { client.postItem(ItemRequest("text", text = "")) }
        refused("badRequest") { client.postItem(ItemRequest("video")) }
        refused("tooLarge") { client.postItem(ItemRequest("text", text = "x".repeat(MAX_TEXT_BYTES + 1))) }
    }

    @Test
    fun aFileGoesUpInChunksAndIsChecked() {
        val client = host.client(host.pair())
        val data = ByteArray(25_000) { (it * 7).toByte() }
        runBlocking {
            Uploader({ client }, chunkBytes = 4000).sendFile(
                ItemRequest("file", name = "data.bin", size = data.size.toLong(), sha256 = sha256Hex(source(data))), source(data),
            )
        }
        assertArrayEquals(data, host.files.bytes(host.files.data.keys.single()))
        assertEquals("Test phone", host.files.folders.values.single())
    }

    @Test
    fun aWrongOffsetAnswers409WithTheOffsetAndTheGuestResumesFromIt() {
        val client = host.client(host.pair())
        val data = ByteArray(9000) { it.toByte() }
        runBlocking {
            val begun = client.postItem(ItemRequest("file", name = "a", size = 9000))
            client.putChunk(begun.id, 0, 4000, source(data))
            val e = refused("offsetMismatch") { client.putChunk(begun.id, 0, 4000, source(data)) }
            assertEquals(409, e.status)
            assertEquals(4000L, e.offset)
            assertEquals(4000L, client.itemState(begun.id).offset)
            assertTrue(client.putChunk(begun.id, 4000, 5000, source(data)).done)
        }
        assertArrayEquals(data, host.files.bytes(host.files.data.keys.single()))
    }

    @Test
    fun aConnectionThatBreaksMidChunkKeepsWhatArrived() {
        val credentials = host.pair()
        val client = host.client(credentials)
        val begun = runBlocking { client.postItem(ItemRequest("file", name = "a", size = 6000)) }
        host.raw(
            "PUT /v1/items/${begun.id}/data HTTP/1.1\r\nHost: x\r\nX-Device-Id: ${credentials.deviceId}\r\nAuthorization: Bearer ${credentials.secret}\r\n" +
                "X-Offset: 0\r\nContent-Length: 6000\r\n\r\n" + "x".repeat(2500),
        ) { it.close() }
        runBlocking {
            withTimeout(5000) { while (client.itemState(begun.id).offset != 2500L) delay(20) }
            val data = ByteArray(6000) { 'x'.code.toByte() }
            assertTrue(client.putChunk(begun.id, 2500, 3500, source(data)).done)
        }
    }

    @Test
    fun aNewerChunkTakesOverFromAStalledOne() {
        val credentials = host.pair()
        val client = host.client(credentials)
        val begun = runBlocking { client.postItem(ItemRequest("file", name = "a", size = 100)) }
        val older = host.raw(
            "PUT /v1/items/${begun.id}/data HTTP/1.1\r\nHost: x\r\nX-Device-Id: ${credentials.deviceId}\r\nAuthorization: Bearer ${credentials.secret}\r\n" +
                "X-Offset: 0\r\nContent-Length: 100\r\n\r\n" + "a".repeat(30),
        ) {
            runBlocking {
                withTimeout(5000) { while (client.itemState(begun.id).offset != 30L) delay(20) }
                val data = ByteArray(100)
                assertTrue(client.putChunk(begun.id, 30, 70, source(data)).done)
            }
        }
        assertEquals("", older)
        assertEquals(100, host.files.bytes(host.files.data.keys.single()).size)
    }

    @Test
    fun anEmptyFileIsDone() {
        val client = host.client(host.pair())
        val result = runBlocking { client.postItem(ItemRequest("file", name = "empty", size = 0)) }
        assertTrue(result.done)
        assertEquals(1, host.files.finished.size)
    }

    @Test
    fun aGalleryIsCheckedAndEachAssetComesOnce() {
        val client = host.client(host.pair())
        val data = ByteArray(10) { 1 }
        runBlocking {
            assertEquals(listOf("a", "b", "c"), client.missingIds(listOf("a", "b", "c", "b")))
            val request = ItemRequest("file", name = "a.jpg", size = 10, sourceId = "a", modified = "2026-01-15T10:00:00Z")
            Uploader({ client }).sendFile(request, source(data))
            assertEquals(listOf("b", "c"), client.missingIds(listOf("a", "b", "c")))
            val again = Uploader({ client }).sendFile(request, source(data))
            assertTrue(again.duplicate)
        }
        assertEquals("Test phone/Gallery/2026-01", host.files.folders.values.single())
        refused("badRequest") { host.client(host.pair("phone-test-0002")).galleryMissing(listOf("bad\u0001id")) }
    }

    @Test
    fun outboxItemsWaitThenArriveAndGoWhenAcknowledged() = runBlocking<Unit> {
        val credentials = host.pair()
        val client = host.client(credentials)
        assertTrue(client.outbox(0).items.isEmpty())
        val waiting = async { client.outbox(5) }
        delay(200)
        host.core.outbox.queueText(credentials.deviceId, "from the phone")
        val reply = waiting.await()
        assertEquals(listOf("from the phone"), reply.items.map { it.text })
        assertNull(reply.more)
        client.acknowledge(reply.items.single().id)
        client.acknowledge(reply.items.single().id)
        assertTrue(client.outbox(0).items.isEmpty())
    }

    @Test
    fun anOutboxReplyHoldsAHundredItemsAndSaysThereIsMore() = runBlocking<Unit> {
        val credentials = host.pair()
        val client = host.client(credentials)
        repeat(150) { host.core.outbox.queueText(credentials.deviceId, "n$it") }
        val first = client.outbox(0)
        assertEquals(100, first.items.size)
        assertEquals(true, first.more)
        first.items.forEach { client.acknowledge(it.id) }
        val rest = client.outbox(0)
        assertEquals(50, rest.items.size)
        assertNull(rest.more)
        assertEquals("n100", rest.items.first().text)
    }

    @Test
    fun outboxTextIsCutAtFourMebibytesButAlwaysSendsOneItem() = runBlocking<Unit> {
        val credentials = host.pair()
        val client = host.client(credentials)
        val big = "x".repeat(MAX_TEXT_BYTES)
        repeat(5) { host.core.outbox.queueText(credentials.deviceId, big) }
        val reply = client.outbox(0)
        assertEquals(4, reply.items.size)
        assertEquals(true, reply.more)
    }

    @Test
    fun anOutboxFileDownloadsWholeResumesWithRangeAndRefusesOtherRanges() = runBlocking<Unit> {
        val credentials = host.pair()
        val client = host.client(credentials)
        val data = ByteArray(5000) { it.toByte() }
        val item = host.core.outbox.queueFile(credentials.deviceId, "pic.jpg", "image/jpeg") { ByteArrayInputStream(data) }
        client.download(item.id, 0).use {
            assertEquals(200, it.status)
            assertEquals(5000L, it.size)
            assertArrayEquals(data, it.body.readBytes())
        }
        client.download(item.id, 1200).use {
            assertEquals(206, it.status)
            assertEquals(5000L, it.size)
            assertArrayEquals(data.copyOfRange(1200, 5000), it.body.readBytes())
        }
        val past = runCatching { client.download(item.id, 5000) }.exceptionOrNull() as LinkException
        assertEquals("rangeNotSatisfiable", past.code)
        val missing = runCatching { client.download("nothing-0001", 0) }.exceptionOrNull() as LinkException
        assertEquals(404, missing.status)
        val raw = host.raw(
            "GET /v1/outbox/${item.id}/data HTTP/1.1\r\nHost: x\r\nX-Device-Id: ${credentials.deviceId}\r\nAuthorization: Bearer ${credentials.secret}\r\n" +
                "Range: bytes=0-10\r\n\r\n",
        )
        assertTrue(raw, raw.startsWith("HTTP/1.1 416"))
        assertTrue(raw, raw.contains("Content-Range: bytes */5000"))
        java.io.File(item.path!!).appendBytes(byteArrayOf(1))
        val changed = runCatching { client.download(item.id, 0) }.exceptionOrNull() as LinkException
        assertEquals("changed", changed.code)
    }

    @Test
    fun anEmptyOutboxFileIsAlwaysSentWhole() = runBlocking<Unit> {
        val credentials = host.pair()
        val client = host.client(credentials)
        val item = host.core.outbox.queueFile(credentials.deviceId, "empty", null) { ByteArrayInputStream(ByteArray(0)) }
        client.download(item.id, 0).use { assertEquals(0L, it.size) }
    }

    @Test
    fun aHungUpLongPollGivesUpItsSlot() = runBlocking<Unit> {
        val credentials = host.pair()
        val client = host.client(credentials)
        val poll = async { runCatching { client.outbox(25) } }
        withTimeout(5000) { while (host.server.activeConnections == 0) delay(20) }
        delay(200)
        poll.cancel()
        withTimeout(5000) { while (host.server.activeConnections != 0) delay(20) }
    }

    @Test
    fun deletingSelfForgetsTheGuestAndWhatWaitedForIt() = runBlocking<Unit> {
        val credentials = host.pair()
        val client = host.client(credentials)
        host.core.outbox.queueText(credentials.deviceId, "waiting")
        val begun = client.postItem(ItemRequest("file", name = "half", size = 50))
        client.forgetSelf()
        assertTrue(host.core.guests.guests.value.isEmpty())
        assertTrue(host.core.outbox.pending(credentials.deviceId).isEmpty())
        assertTrue(host.files.data.isEmpty())
        val e = runCatching { client.itemState(begun.id) }.exceptionOrNull() as LinkException
        assertEquals(401, e.status)
    }

    @Test
    fun helloListsTheAddressesAndTheChunkLimit() = runBlocking<Unit> {
        val hello = host.client(host.pair()).hello()
        assertEquals(listOf("127.0.0.1"), hello.addresses)
        assertEquals(MAX_CHUNK_BYTES, hello.maxChunkBytes)
        assertEquals("host-test-0001", hello.desktopId)
    }

    @Test
    fun peersOnOtherNetworksAreClosedBeforeTls() {
        host.close()
        val refusing = object : HostNetworks({ emptyList() }) {
            override fun allowsPeer(remote: InetAddress) = false
        }
        HostFixture(refusing).use { closed ->
            try {
                runBlocking { closed.client().health() }
                fail()
            } catch (e: IOException) {
            }
        }
    }

    @Test
    fun connectionsOnAnInterfaceThatIsNotAHostInterfaceAreClosed() {
        host.close()
        val refusing = object : HostNetworks({ emptyList() }) {
            override fun allowsLocal(local: InetAddress) = false
        }
        HostFixture(refusing).use { closed ->
            try {
                runBlocking { closed.client().health() }
                fail()
            } catch (e: IOException) {
            }
        }
    }

    @Test
    fun theHeadIsReadStrictly() {
        val credentials = host.pair()
        val auth = "X-Device-Id: ${credentials.deviceId}\r\nAuthorization: Bearer ${credentials.secret}\r\n"
        fun status(request: String) = host.raw(request).substringBefore("\r\n")
        assertTrue(status("POST /v1/items HTTP/1.1\r\nHost: x\r\n${auth}Transfer-Encoding: chunked\r\n\r\n").contains("501"))
        assertTrue(status("POST /v1/items HTTP/1.1\r\nHost: x\r\n$auth\r\n").contains("411"))
        assertTrue(status("GET /v1/health HTTP/1.0\r\nHost: x\r\n\r\n").contains("505"))
        assertTrue(status("GET /v1/health HTTP/1.1\r\n\r\n").contains("400"))
        assertTrue(status("GET /v1/health HTTP/1.1\nHost: x\n\n").contains("400"))
        assertTrue(status("PATCH /v1/health HTTP/1.1\r\nHost: x\r\n\r\n").contains("501"))
        assertTrue(status("GET /v1/nothing HTTP/1.1\r\nHost: x\r\n\r\n").contains("404"))
        assertTrue(status("POST /v1/health HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n").contains("405"))
        assertTrue(status("PUT /v1/items/aaaaaaaa/data HTTP/1.1\r\nHost: x\r\n${auth}X-Offset: 0\r\n\r\n").contains("411"))
        val answer = host.raw("GET /v1/health HTTP/1.1\r\nHost: x\r\n\r\n")
        assertTrue(answer, answer.contains("Connection: close"))
    }

    @Test
    fun aClientThatWaitsForContinueGetsItAndARefusedBodyIsNotRead() {
        val credentials = host.pair()
        val auth = "X-Device-Id: ${credentials.deviceId}\r\nAuthorization: Bearer ${credentials.secret}\r\n"
        val body = """{"kind":"text","text":"waited"}"""
        val sent = host.raw("POST /v1/items HTTP/1.1\r\nHost: x\r\n${auth}Expect: 100-continue\r\nContent-Length: ${body.length}\r\n\r\n") { socket ->
            val answer = ByteArray(25)
            var read = 0
            while (read < answer.size) read += socket.inputStream.read(answer, read, answer.size - read)
            assertEquals("HTTP/1.1 100 Continue\r\n\r\n", String(answer))
            socket.outputStream.write(body.toByteArray())
            socket.outputStream.flush()
        }
        assertTrue(sent, sent.startsWith("HTTP/1.1 201"))
        assertEquals(listOf("waited"), texts.map { it.third })
        val refused = host.raw("POST /v1/items HTTP/1.1\r\nHost: x\r\nX-Device-Id: bad-device-0001\r\nAuthorization: Bearer x\r\nExpect: 100-continue\r\nContent-Length: 50\r\n\r\n")
        assertTrue(refused, refused.startsWith("HTTP/1.1 401"))
        assertFalse(refused.contains("100 Continue"))
    }
}
