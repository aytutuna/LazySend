package com.lazysend.lazysend.host

import com.lazysend.lazysend.link.Credentials
import com.lazysend.lazysend.link.Endpoint
import com.lazysend.lazysend.link.LinkClient
import com.lazysend.lazysend.link.PinnedTrustManager
import com.lazysend.lazysend.transfer.MemFiles
import java.io.File
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/** A host on loopback with the app's own TLS identity, its files in memory, and the app's own client to talk to it. */
class HostFixture(networks: HostNetworks = HostNetworks({ emptyList() })) : AutoCloseable {
    val dir = File.createTempFile("host", "").also { it.delete(); it.mkdirs() }
    val files = MemFiles(0)
    var free = 100L * 1024 * 1024 * 1024
    private val keys = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    val identity = HostIdentity(File(dir, "cert.der"), keys.private, keys.public, { "Pixel" })
    val core = HostCore(File(dir, "host"), files, { "host-test-0001" }, { "Pixel host" }, { free })
    val server = HostServer(identity.sslContext(), core.router, core.limiter, networks)
    val port = server.start(0)

    init {
        core.router.fingerprint = { identity.fingerprint }
        core.router.addresses = { listOf("127.0.0.1") }
        core.load()
    }

    fun client(credentials: Credentials? = null) = LinkClient(Endpoint("127.0.0.1", port), identity.fingerprint, credentials)

    /** Opens pairing and answers the prompt like a person would; returns the guest's credentials. */
    fun pair(id: String = "phone-test-0001", allow: Boolean = true, useShortCode: Boolean = false): Credentials = runBlocking {
        coroutineScope {
            val session = core.openPairing()
            launch { core.approval.filterNotNull().first().respond(allow) }
            val token = if (useShortCode) session.shortCodeText.lowercase() else session.tokenText
            val reply = client().pair(token, id, "Test phone", "1.0")
            Credentials(id, reply.deviceSecret)
        }
    }

    /** One raw request over TLS pinned to the host's key; the answer up to the connection closing. */
    fun raw(request: String, hold: (SSLSocket) -> Unit = {}): String {
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(PinnedTrustManager(identity.fingerprint)), SecureRandom()) }
        (tls.socketFactory.createSocket("127.0.0.1", port) as SSLSocket).use { socket ->
            socket.soTimeout = 10_000
            socket.outputStream.write(request.toByteArray(Charsets.ISO_8859_1))
            socket.outputStream.flush()
            hold(socket)
            // A connection the host cut off (a takeover, a refusal) may end in a reset instead of a clean close.
            val answer = java.io.ByteArrayOutputStream()
            try {
                socket.inputStream.copyTo(answer)
            } catch (e: java.io.IOException) {
            }
            return answer.toString(Charsets.ISO_8859_1)
        }
    }

    override fun close() {
        runBlocking { server.stop() }
    }
}

