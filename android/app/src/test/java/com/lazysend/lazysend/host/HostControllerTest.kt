package com.lazysend.lazysend.host

import com.lazysend.lazysend.data.Direction
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.EntryState
import com.lazysend.lazysend.data.Timeline
import com.lazysend.lazysend.link.Credentials
import com.lazysend.lazysend.link.Endpoint
import com.lazysend.lazysend.link.ItemRequest
import com.lazysend.lazysend.link.LinkClient
import com.lazysend.lazysend.link.PairingCode
import com.lazysend.lazysend.transfer.MemFiles
import java.io.File
import java.net.ServerSocket
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostControllerTest {
    private val root = File.createTempFile("controller", "").also { it.delete(); it.mkdirs() }
    private val started = mutableListOf<HostController>()

    private fun keys(): KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()

    private fun controller(key: KeyPair = pair, port: Int = 0): HostController {
        val identity = HostIdentity(File(root, "cert.der"), key.private, key.public, { "Pixel" })
        return HostController(
            File(root, "host"), MemFiles(0), Timeline(File(root, "timeline.json")), { "host-test-0001" }, { "Pixel host" }, { 100L shl 30 },
            { identity }, HostNetworks({ emptyList() }), null, preferredPort = port,
        ).also { started.add(it) }
    }

    private val pair = keys()

    @After
    fun stop() {
        started.forEach { it.stop() }
        runBlocking { delay(100) }
    }

    private suspend fun waitFor(condition: () -> Boolean) {
        withTimeout(10_000) { while (!condition()) delay(20) }
    }

    private suspend fun pairGuest(host: HostController, id: String = "phone-test-0001"): Credentials = coroutineScope {
        val code = PairingCode.parse(host.state.value.pairing!!.link)
        val client = LinkClient(Endpoint("127.0.0.1", code.port), code.pin, null)
        val reply = async { client.pair(code.token, id, "Guest phone", "1.0") }
        host.core.approval.filterNotNull().first()
        host.answer(true)
        Credentials(id, reply.await().deviceSecret)
    }

    @Test
    fun openingTheScreenListensAndShowsACodeAGuestCanUse() = runBlocking {
        val host = controller()
        host.open()
        waitFor { host.state.value.pairing != null }
        val shown = host.state.value
        assertTrue(shown.running)
        assertTrue(shown.port > 0)
        assertEquals(Fingerprint.spaced(Fingerprint.checkCode(sha256(pair.public.encoded))), shown.pairing!!.checkDigits)
        val code = PairingCode.parse(shown.pairing.link)
        assertEquals("host-test-0001", code.desktopId)
        assertEquals("Pixel host", code.name)
        val credentials = pairGuest(host)
        assertEquals("phone-test-0001", host.core.guests.get(credentials.deviceId)!!.id)
    }

    @Test
    fun leavingStopsTheServerUnlessAGuestIsPaired() = runBlocking {
        val host = controller()
        host.open()
        waitFor { host.state.value.pairing != null }
        pairGuest(host)
        host.leave()
        assertNull(host.state.value.pairing)
        assertTrue(host.state.value.running)
        assertTrue(host.keepAlive.value || run { delay(200); host.keepAlive.value })
        host.removeGuest("phone-test-0001")
        host.leave()
        waitFor { !host.state.value.running }
    }

    @Test
    fun aTakenPortFallsBackToAFreeOne() = runBlocking {
        ServerSocket(0).use { taken ->
            val host = controller(port = taken.localPort)
            host.open()
            waitFor { host.state.value.running }
            assertNotEquals(taken.localPort, host.state.value.port)
        }
    }

    @Test
    fun aListenerThatFailsIsStartedAgain() = runBlocking {
        val host = controller()
        host.open()
        waitFor { host.state.value.running }
        val first = host.currentServer!!
        first.listener!!.close()
        waitFor { host.currentServer != null && host.currentServer !== first && host.state.value.running }
        assertTrue(host.state.value.port > 0)
    }

    @Test
    fun aNewKeyDropsEveryPairing() = runBlocking {
        val host = controller()
        host.open()
        waitFor { host.state.value.pairing != null }
        pairGuest(host)
        host.stop()
        waitFor { !host.state.value.running }
        val other = controller(keys())
        File(root, "cert.der").delete()
        other.open()
        waitFor { other.state.value.running }
        assertTrue(other.core.guests.guests.value.isEmpty())
        other.leave()
    }

    @Test
    fun theSameKeyKeepsThem() = runBlocking {
        val host = controller()
        host.open()
        waitFor { host.state.value.pairing != null }
        pairGuest(host)
        host.stop()
        waitFor { !host.state.value.running }
        val again = controller()
        again.open()
        waitFor { again.state.value.running }
        assertEquals(1, again.core.guests.guests.value.size)
    }

    @Test
    fun whatArrivesAndWhatWaitsShowsInTheTimeline() = runBlocking {
        val host = controller()
        host.open()
        waitFor { host.state.value.pairing != null }
        val credentials = pairGuest(host)
        val port = host.state.value.port
        val client = LinkClient(Endpoint("127.0.0.1", port), sha256(pair.public.encoded), credentials)
        client.postItem(ItemRequest("text", text = "hello phone"))
        client.postItem(ItemRequest("file", name = "a.txt", size = 0))
        val timeline = Timeline(File(root, "timeline.json")).entries.value
        assertTrue(timeline.any { it.kind == EntryKind.Text && it.title == "hello phone" && it.direction == Direction.Received && it.pcName == "Guest phone" })
        assertTrue(timeline.any { it.kind == EntryKind.File && it.title == "a.txt" && it.state == EntryState.Done })

        val guest = host.core.guests.get(credentials.deviceId)!!
        assertNull(host.queueText(guest, "see https://alazy.app"))
        assertNull(host.queueText(guest, "https://alazy.app/send/"))
        val items = client.outbox(0).items
        assertEquals(listOf("text", "link"), items.map { it.kind })
        items.forEach { client.acknowledge(it.id) }
        val after = Timeline(File(root, "timeline.json")).entries.value
        assertEquals(2, after.count { it.direction == Direction.Sent && it.state == EntryState.Done })
        assertFalse(after.any { it.direction == Direction.Sent && it.state == EntryState.Active })
    }

    @Test
    fun pausingKeepsTheCodeGoodAndDeclinesOnlyWhatWaits() = runBlocking {
        val host = controller()
        host.open()
        waitFor { host.state.value.pairing != null }
        val link = host.state.value.pairing!!.link
        host.pause()
        // The code was shared from this screen, so it still pairs a device while the app is out of view.
        val code = PairingCode.parse(link)
        val client = LinkClient(Endpoint("127.0.0.1", code.port), code.pin, null)
        val reply = async { runCatching { client.pair(code.token, "phone-test-0001", "Guest phone", "1.0") } }
        val asked = host.core.approval.filterNotNull().first()
        host.pause()
        assertFalse(reply.await().isSuccess)
        assertEquals(false, asked.answer.await())
        assertTrue(host.state.value.running)
    }

    @Test
    fun leavingClosesTheCode() = runBlocking {
        val host = controller()
        host.open()
        waitFor { host.state.value.pairing != null }
        val code = PairingCode.parse(host.state.value.pairing!!.link)
        host.pause()
        host.leave()
        val client = LinkClient(Endpoint("127.0.0.1", code.port), code.pin, null)
        val failure = runCatching { client.pair(code.token, "phone-test-0001", "x", "1") }.exceptionOrNull()
        assertTrue(failure is com.lazysend.lazysend.link.LinkException || failure is java.io.IOException)
    }

    @Test
    fun openingAgainKeepsTheCodeAndTheServer() = runBlocking {
        val host = controller()
        host.open()
        waitFor { host.state.value.pairing != null }
        val before = host.state.value
        val server = host.currentServer
        host.open()
        assertEquals(before.pairing!!.link, host.state.value.pairing!!.link)
        assertEquals(before.port, host.state.value.port)
        assertTrue(server === host.currentServer)
    }
}
