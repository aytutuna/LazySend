package com.lazysend.lazysend.link

import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import kotlinx.serialization.encodeToString
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import mockwebserver3.SocketEffect
import okhttp3.Headers
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate

const val TEST_DEVICE = "phone-test-0001"
const val TEST_SECRET = "c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0LXNlY3JldA"
const val TEST_TOKEN = "dG9rZW4tdG9rZW4tdG9r"

/** A stand-in for the PC's link server, over TLS with a certificate of its own, keeping what the phone does to it. */
class FakePc : AutoCloseable {
    val certificate: HeldCertificate = HeldCertificate.Builder().ecdsa256().commonName("fake-pc").build()
    val pin: ByteArray = MessageDigest.getInstance("SHA-256").digest(certificate.certificate.publicKey.encoded)
    private val server = MockWebServer()

    val requests = mutableListOf<String>()
    val received = ByteArrayOutputStream()
    val galleryBatches = mutableListOf<Int>()
    val items = mutableListOf<ItemRequest>()
    var fileSize = 0L
    var fileHash: String? = null
    var texts = mutableListOf<String>()
    var tokenAccepted = true
    var outbox = mutableListOf<OutboxEntry>()
    var outboxFile = ByteArray(0)
    val acknowledged = mutableListOf<String>()
    val have = mutableSetOf<String>()

    /** What happens to the next chunk requests, in order. */
    val chunkDrops = ArrayDeque<Drop>()

    /** Error answers (status to code) given to the next chunk requests, in order. */
    val chunkErrors = ArrayDeque<Pair<Int, String>>()

    enum class Drop { None, AnswerLost }

    val endpoint get() = Endpoint(server.hostName, server.port)

    init {
        val handshake = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        server.useHttps(handshake.sslSocketFactory())
        server.protocols = listOf(okhttp3.Protocol.HTTP_1_1)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = synchronized(this@FakePc) { handle(request) }
        }
        server.start()
    }

    fun client(pin: ByteArray = this.pin, credentials: Credentials? = Credentials(TEST_DEVICE, TEST_SECRET)) =
        LinkClient(endpoint, pin, credentials)

    private fun json(code: Int, body: String) = MockResponse.Builder().code(code)
        .addHeader("Content-Type", "application/json; charset=utf-8").body(body).build()

    private fun error(code: Int, name: String, offset: Long? = null) =
        json(code, LinkJson.encodeToString(ApiError(name, "message for $name", offset)))

    private fun handle(request: RecordedRequest): MockResponse {
        val path = request.url.encodedPath
        requests += "${request.method} $path"
        val open = path == "/v1/health" || path == "/v1/pair"
        if (!open && (request.headers["X-Device-Id"].isNullOrEmpty() || request.headers["Authorization"] != "Bearer $TEST_SECRET")) {
            return error(401, "unauthorized")
        }
        val body = request.body?.utf8() ?: ""
        return when {
            path == "/v1/health" -> json(200, """{"service":"lazysend","protocolVersion":1,"paired":false}""")
            path == "/v1/pair" -> {
                val pair = LinkJson.decodeFromString<PairRequest>(body)
                if (!tokenAccepted || pair.token != TEST_TOKEN) error(403, "tokenInvalid")
                else json(200, LinkJson.encodeToString(PairResponse(1, "desktop-test-01", "Test PC", TEST_SECRET)))
            }
            path == "/v1/hello" -> json(200, """{"protocolVersion":1,"desktopId":"desktop-test-01","desktopName":"Test PC","maxChunkBytes":67108864,"addresses":["192.168.42.10"]}""")
            path == "/v1/items" && request.method == "POST" -> postItem(LinkJson.decodeFromString(body))
            path.startsWith("/v1/items/") && path.endsWith("/data") -> putChunk(request)
            path.startsWith("/v1/items/") -> json(200, LinkJson.encodeToString(state()))
            path == "/v1/gallery/check" -> {
                val ids = LinkJson.decodeFromString<GalleryCheckRequest>(body).ids
                galleryBatches += ids.size
                json(200, LinkJson.encodeToString(GalleryCheckReply(ids.filter { it !in have })))
            }
            path == "/v1/outbox" -> json(200, LinkJson.encodeToString(OutboxReply(outbox.toList())))
            path.startsWith("/v1/outbox/") && path.endsWith("/data") -> outboxData(request)
            path.startsWith("/v1/outbox/") && request.method == "DELETE" -> {
                acknowledged += path.removePrefix("/v1/outbox/")
                outbox.removeAll { it.id == path.removePrefix("/v1/outbox/") }
                MockResponse.Builder().code(204).build()
            }
            path == "/v1/devices/self" -> MockResponse.Builder().code(204).build()
            else -> error(404, "notFound")
        }
    }

    private fun state() = ItemState("item00000001", received.size().toLong(), received.size().toLong() == fileSize)

    private fun postItem(item: ItemRequest): MockResponse {
        items += item
        return when (item.kind) {
            "text", "link" -> {
                texts += item.text ?: item.url ?: ""
                json(201, LinkJson.encodeToString(ItemState("item00000002", 0, true)))
            }
            else -> {
                if (item.sourceId in have) return json(200, LinkJson.encodeToString(ItemState("", item.size!!, true, true)))
                fileSize = item.size!!
                fileHash = item.sha256
                json(201, LinkJson.encodeToString(state().copy(done = fileSize == 0L)))
            }
        }
    }

    private fun putChunk(request: RecordedRequest): MockResponse {
        chunkErrors.removeFirstOrNull()?.let { return error(it.first, it.second) }
        val drop = chunkDrops.removeFirstOrNull() ?: Drop.None
        val offset = request.headers["X-Offset"]!!.toLong()
        if (offset != received.size().toLong()) return error(409, "offsetMismatch", received.size().toLong())
        received.write(request.body!!.toByteArray())
        if (drop == Drop.AnswerLost) return MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()
        val done = received.size().toLong() == fileSize
        if (done && fileHash != null) {
            val hash = MessageDigest.getInstance("SHA-256").digest(received.toByteArray()).joinToString("") { "%02x".format(it) }
            if (hash != fileHash) {
                received.reset()
                return error(422, "hashMismatch")
            }
        }
        return json(200, LinkJson.encodeToString(state()))
    }

    private fun outboxData(request: RecordedRequest): MockResponse {
        val range = request.headers["Range"]
        val from = range?.removePrefix("bytes=")?.removeSuffix("-")?.toInt() ?: 0
        if (range != null && outboxFile.isNotEmpty() && from >= outboxFile.size) return error(416, "rangeNotSatisfiable")
        val part = outboxFile.copyOfRange(from, outboxFile.size)
        val builder = MockResponse.Builder().code(if (range == null) 200 else 206)
            .headers(Headers.headersOf("Accept-Ranges", "bytes", "Content-Type", "application/octet-stream"))
        val data = okio.Buffer().write(part)
        return builder.body(data).build()
    }

    override fun close() = server.close()
}
