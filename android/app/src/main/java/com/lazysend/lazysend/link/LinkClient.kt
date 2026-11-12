package com.lazysend.lazysend.link

import java.io.InputStream
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import kotlinx.serialization.encodeToString
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.ConnectionSpec
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.coroutines.executeAsync
import okio.BufferedSink

data class Endpoint(val host: String, val port: Int)

data class Credentials(val deviceId: String, val secret: String)

/** Trusts the one certificate whose public key hashes to [pin], whatever its name or issuer. */
class PinnedTrustManager(private val pin: ByteArray) : X509TrustManager {
    override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = throw CertificateException("no client certificates")

    override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
        val leaf = chain.firstOrNull() ?: throw CertificateException("empty chain")
        // PublicKey.getEncoded() is the DER SubjectPublicKeyInfo, which is what the pin hashes.
        val hash = MessageDigest.getInstance("SHA-256").digest(leaf.publicKey.encoded)
        if (!MessageDigest.isEqual(hash, pin)) throw CertificateException("certificate does not match the pairing code")
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

fun pinnedHttpClient(pin: ByteArray, base: OkHttpClient = OkHttpClient()): OkHttpClient {
    val trust = PinnedTrustManager(pin)
    val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), SecureRandom()) }
    return base.newBuilder()
        .sslSocketFactory(tls.socketFactory, trust)
        .hostnameVerifier { _, _ -> true }
        .connectionSpecs(listOf(ConnectionSpec.MODERN_TLS))
        .protocols(listOf(Protocol.HTTP_1_1))
        .retryOnConnectionFailure(false)
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()
}

fun interface DataSource {
    fun open(offset: Long): InputStream
}

class Download(val status: Int, val size: Long, val body: InputStream, private val response: Response) : AutoCloseable {
    override fun close() = response.close()
}

/** One PC at one address, over TLS pinned to its key. Every call is a connection of its own, as the PC closes after each answer. */
class LinkClient(val endpoint: Endpoint, pin: ByteArray, private val credentials: Credentials?, base: OkHttpClient = OkHttpClient()) {
    private val http = pinnedHttpClient(pin, base)

    private fun url(path: String, query: Map<String, String> = emptyMap()): HttpUrl {
        val builder = HttpUrl.Builder().scheme("https").host(endpoint.host.removeSurrounding("[", "]")).port(endpoint.port).encodedPath(path)
        query.forEach { (k, v) -> builder.addQueryParameter(k, v) }
        return builder.build()
    }

    private fun request(path: String, query: Map<String, String> = emptyMap(), auth: Boolean = true) =
        Request.Builder().url(url(path, query)).also {
            if (auth && credentials != null) {
                it.header("X-Device-Id", credentials.deviceId)
                it.header("Authorization", "Bearer ${credentials.secret}")
            }
        }

    private fun json(value: String) = value.toRequestBody(JSON_TYPE)

    // Reading the answer is blocking I/O and may be reached from the main thread.
    private suspend fun <T> send(request: Request.Builder, client: OkHttpClient = http, read: (Response) -> T): T =
        withContext(Dispatchers.IO) {
            client.newCall(request.build()).executeAsync().use { response ->
                if (!response.isSuccessful) throw errorOf(response)
                read(response)
            }
        }

    private inline fun <reified T> parse(response: Response): T = LinkJson.decodeFromString(response.body.string())

    private fun errorOf(response: Response): LinkException {
        val text = runCatching { response.body.string() }.getOrDefault("")
        val api = runCatching { LinkJson.decodeFromString<ApiError>(text) }.getOrNull()
        return LinkException(response.code, api?.error ?: "http${response.code}", api?.message?.ifEmpty { null } ?: "The computer answered ${response.code}.", api?.offset)
    }

    suspend fun health(): Health = send(request("/v1/health")) { parse(it) }

    /** Waits for the person at the PC: it answers after they approve, or declines after 120 seconds. */
    suspend fun pair(token: String, phoneId: String, phoneName: String, appVersion: String): PairResponse {
        val patient = http.newBuilder().readTimeout(130, TimeUnit.SECONDS).build()
        val body = json(LinkJson.encodeToString(PairRequest(token, phoneId, phoneName, appVersion = appVersion)))
        return send(request("/v1/pair", auth = false).post(body), patient) { parse(it) }
    }

    suspend fun hello(): Hello = send(request("/v1/hello")) { parse(it) }

    suspend fun forgetSelf() = send(request("/v1/devices/self").delete()) { }

    suspend fun postItem(item: ItemRequest): ItemState =
        send(request("/v1/items").post(json(LinkJson.encodeToString(item)))) { parse(it) }

    suspend fun itemState(id: String): ItemState = send(request("/v1/items/$id")) { parse(it) }

    /** Sends [length] bytes of [source] from [offset]; [onBytes] counts what was written to the connection. */
    suspend fun putChunk(id: String, offset: Long, length: Long, source: DataSource, onBytes: (Long) -> Unit = {}): ItemState {
        val body = object : RequestBody() {
            override fun contentType() = OCTET_STREAM
            override fun contentLength() = length
            override fun writeTo(sink: BufferedSink) {
                source.open(offset).use { input ->
                    val buffer = ByteArray(64 * 1024)
                    var left = length
                    while (left > 0) {
                        val n = input.read(buffer, 0, minOf(buffer.size.toLong(), left).toInt())
                        if (n < 0) throw java.io.EOFException("The file is shorter than it was.")
                        sink.write(buffer, 0, n)
                        left -= n
                        onBytes(n.toLong())
                    }
                }
            }
        }
        val request = request("/v1/items/$id/data").header("X-Offset", offset.toString()).put(body)
        return send(request) { parse(it) }
    }

    /** The ids of [ids] (at most [GALLERY_BATCH]) the PC has not received from this phone. */
    suspend fun galleryMissing(ids: List<String>): List<String> =
        send(request("/v1/gallery/check").post(json(LinkJson.encodeToString(GalleryCheckRequest(ids))))) { parse<GalleryCheckReply>(it).missing }

    suspend fun outbox(waitSeconds: Int): OutboxReply {
        val client = http.newBuilder().readTimeout((waitSeconds + 15).toLong(), TimeUnit.SECONDS).build()
        return send(request("/v1/outbox", mapOf("wait" to waitSeconds.coerceIn(0, MAX_OUTBOX_WAIT).toString())), client) { parse(it) }
    }

    /** Opens the file of an outbox item from [from]; the caller closes it. */
    suspend fun download(id: String, from: Long): Download {
        val request = request("/v1/outbox/$id/data").also { if (from > 0) it.header("Range", "bytes=$from-") }
        val response = http.newCall(request.build()).executeAsync()
        if (!response.isSuccessful) throw response.use { errorOf(it) }
        val length = response.body.contentLength()
        val size = if (response.code == 206) from + length else length
        return Download(response.code, size, response.body.byteStream(), response)
    }

    suspend fun acknowledge(id: String) = send(request("/v1/outbox/$id").delete()) { }

    companion object {
        private val JSON_TYPE = "application/json; charset=utf-8".toMediaType()
        private val OCTET_STREAM = "application/octet-stream".toMediaType()
    }
}
