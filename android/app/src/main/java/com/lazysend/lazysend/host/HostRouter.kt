package com.lazysend.lazysend.host

import com.lazysend.lazysend.link.GalleryCheckReply
import com.lazysend.lazysend.link.GalleryCheckRequest
import com.lazysend.lazysend.link.Health
import com.lazysend.lazysend.link.Hello
import com.lazysend.lazysend.link.ItemRequest
import com.lazysend.lazysend.link.ItemState
import com.lazysend.lazysend.link.LinkJson
import com.lazysend.lazysend.link.OutboxEntry
import com.lazysend.lazysend.link.OutboxReply
import com.lazysend.lazysend.link.PairResponse
import com.lazysend.lazysend.link.PROTOCOL_VERSION
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString

/** Lenient on purpose: other guests leave out what they have no value for. */
@Serializable
class PairBody(
    val token: String = "",
    val phoneId: String = "",
    val phoneName: String = "",
    val platform: String = "",
    val appVersion: String = "",
)

/**
 * What the host does with each request (the routes are in CONTRACTS.md). Unpaired clients may only check reachability and
 * pair with the open session's token or short code; everything else needs a guest's id and secret, and a wrong secret gets
 * 401. Every request counts towards its sender's rate limit, every failed secret or token towards its failure limit.
 */
class HostRouter(
    private val guests: GuestStore,
    private val inbox: Inbox,
    private val outbox: Outbox,
    private val gallery: GalleryIndex,
    private val limiter: RateLimiter,
    private val hostId: () -> String,
    private val hostName: () -> String,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /** The host's addresses now, for hello, so a guest paired on one network finds it on another. */
    var addresses: () -> List<String> = { emptyList() }

    /** The pairing session open now; null when pairing is not open. */
    var currentPairing: () -> PairingSession? = { null }

    /** The key's fingerprint, for the match digits of a pairing by short code. */
    var fingerprint: () -> ByteArray = { ByteArray(0) }

    /** Asks the person whether the guest that presented a valid token may pair, with the six digits both screens show. */
    var approve: suspend (PairBody, String) -> Boolean = { _, _ -> false }
    var approvalTimeoutMs = 120_000L

    var onGuestPaired: (Guest) -> Unit = {}
    var onGuestRemoved: (Guest) -> Unit = {}
    var onText: (Guest, String, String) -> Unit = { _, _, _ -> }
    var onAcknowledged: (OutboxItem) -> Unit = {}

    suspend fun handle(request: HostRequest): HostResponse {
        val now = clock()
        if (!limiter.tryRequest(request.peer, now)) return respond(HostError.rateLimited)
        return try {
            route(request, now)
        } catch (e: HostError) {
            respond(e)
        }
    }

    private fun respond(e: HostError): HostResponse = when (e.status) {
        401 -> HostResponse.error(e, "WWW-Authenticate" to "Bearer")
        429 -> HostResponse.error(e, "Retry-After" to "60")
        else -> HostResponse.error(e)
    }

    private suspend fun route(request: HostRequest, now: Long): HostResponse {
        val head = request.head
        val path = head.path
        when (path) {
            "/v1/health" -> return if (allows(head, "GET")) health(request, now) else notAllowed("GET")
            "/v1/pair" -> return if (allows(head, "POST")) pair(request, now) else notAllowed("POST")
            "/v1/hello" -> return if (allows(head, "GET")) hello(request, now) else notAllowed("GET")
            "/v1/devices/self" -> return if (allows(head, "DELETE")) removeSelf(request, now) else notAllowed("DELETE")
            "/v1/items" -> return if (allows(head, "POST")) postItem(request, now) else notAllowed("POST")
            "/v1/gallery/check" -> return if (allows(head, "POST")) galleryCheck(request, now) else notAllowed("POST")
            "/v1/outbox" -> return if (allows(head, "GET")) outbox(request, now) else notAllowed("GET")
        }
        if (path.startsWith("/v1/items/")) {
            val rest = path.removePrefix("/v1/items/")
            if (rest.endsWith("/data")) return if (allows(head, "PUT")) putChunk(request, rest.removeSuffix("/data"), now) else notAllowed("PUT")
            return if (allows(head, "GET")) itemStatus(request, rest, now) else notAllowed("GET")
        }
        if (path.startsWith("/v1/outbox/")) {
            val rest = path.removePrefix("/v1/outbox/")
            if (rest.endsWith("/data")) return if (allows(head, "GET")) outboxData(request, rest.removeSuffix("/data"), now) else notAllowed("GET")
            return if (allows(head, "DELETE")) acknowledge(request, rest, now) else notAllowed("DELETE")
        }
        throw HostError.notFound
    }

    private fun allows(head: RequestHead, method: String) = head.method == method

    private fun notAllowed(allow: String) = HostResponse.error(HostError.methodNotAllowed, "Allow" to allow)

    /** The paired guest the request comes from; a failure is counted when its id and secret do not match one. */
    private fun authenticate(request: HostRequest, now: Long): Guest =
        guests.authenticate(request.head.header("X-Device-Id"), request.head.bearer, now)
            ?: run {
                limiter.recordFailure(request.peer, now)
                throw HostError.unauthorized
            }

    private fun health(request: HostRequest, now: Long): HostResponse {
        var paired = false
        if (request.head.bearer != null || request.head.header("X-Device-Id") != null) {
            authenticate(request, now)
            paired = true
        }
        return HostResponse.json(200, Health("lazysend", PROTOCOL_VERSION, paired))
    }

    private fun hello(request: HostRequest, now: Long): HostResponse {
        authenticate(request, now)
        return HostResponse.json(200, Hello(PROTOCOL_VERSION, hostId(), hostName(), MAX_CHUNK_BYTES, addresses()))
    }

    private suspend fun pair(request: HostRequest, now: Long): HostResponse {
        val length = request.head.contentLength ?: throw HostError.lengthRequired
        if (length > MAX_SMALL_BODY) throw HostError.tooLarge
        // Before the body is read: a body is only worth waiting for while a code is shown.
        val session = currentPairing() ?: throw HostError.pairingClosed
        val pair = json<PairBody>(request.body.readAll())
        if (!isValidId(pair.phoneId)) throw HostError.badRequest
        val name = cleanName(pair.phoneName).ifEmpty { "Phone" }
        val approved = request.whileConnected {
            when (session.redeem(pair.token, now, request.peer)) {
                Redeem.Accepted -> Unit
                Redeem.WrongToken -> {
                    limiter.recordFailure(request.peer, now)
                    throw HostError.tokenInvalid
                }
                Redeem.Expired -> throw HostError.tokenExpired
                Redeem.AlreadyUsed -> throw HostError.tokenUsed
                Redeem.Closed -> throw HostError.pairingClosed
            }
            val fingerprint = fingerprint()
            val code = PairingSession.normalizeShortCode(pair.token)
            val digits = Fingerprint.spaced(if (code != null) Fingerprint.matchCode(fingerprint, code) else Fingerprint.checkCode(fingerprint))
            // Without an answer in time the pairing is declined.
            withTimeoutOrNull(approvalTimeoutMs) { approve(pair, digits) } ?: false
        }
        // Stored only once the guest is known to still be there, outside the wait that a hang-up cancels.
        if (!approved || request.peerGone) throw HostError.declined
        return run {
            val secret = try {
                guests.pair(pair.phoneId, name, cleanName(pair.platform), cleanName(pair.appVersion), clock())
            } catch (e: TooManyGuests) {
                throw HostError.tooManyGuests
            } catch (e: IOException) {
                throw HostError.serverError
            }
            // The guest counts as paired once it has the secret; when the answer never got to it, it is forgotten again.
            HostResponse.json(200, PairResponse(PROTOCOL_VERSION, hostId(), hostName(), secret)).withWritten { delivered ->
                if (!delivered) {
                    guests.get(pair.phoneId)?.let(onGuestRemoved)
                    guests.remove(pair.phoneId)
                } else {
                    guests.get(pair.phoneId)?.let(onGuestPaired)
                }
            }
        }
    }

    private fun removeSelf(request: HostRequest, now: Long): HostResponse {
        val guest = authenticate(request, now)
        onGuestRemoved(guest)
        return HostResponse.empty(204)
    }

    private suspend fun postItem(request: HostRequest, now: Long): HostResponse {
        val guest = authenticate(request, now)
        val length = request.head.contentLength ?: throw HostError.lengthRequired
        if (length > MAX_ITEM_BODY) throw HostError.tooLarge
        val item = json<ItemRequest>(request.body.readAll())
        when (item.kind) {
            "text" -> {
                val text = item.text
                if (text.isNullOrEmpty()) throw HostError.badRequest
                if (text.toByteArray().size > MAX_TEXT_BYTES) throw HostError.tooLarge
                onText(guest, "text", text)
                return HostResponse.json(201, ItemState(newId(), 0, true))
            }
            "link" -> {
                if (!isAcceptableUrl(item.url)) throw HostError.badRequest
                onText(guest, "link", item.url!!)
                return HostResponse.json(201, ItemState(newId(), 0, true))
            }
            "file" -> {
                val state = withContext(Dispatchers.IO) { inbox.begin(guest, item) }
                return HostResponse.json(if (state.done) 200 else 201, state)
            }
            else -> throw HostError.badRequest
        }
    }

    private suspend fun itemStatus(request: HostRequest, id: String, now: Long): HostResponse {
        val guest = authenticate(request, now)
        val state = if (isValidId(id)) withContext(Dispatchers.IO) { inbox.state(guest.id, id) } else null
        return HostResponse.json(200, state ?: throw HostError.notFound)
    }

    private suspend fun putChunk(request: HostRequest, id: String, now: Long): HostResponse {
        val guest = authenticate(request, now)
        if (!isValidId(id)) throw HostError.notFound
        val length = request.head.contentLength ?: throw HostError.lengthRequired
        if (length > MAX_CHUNK_BYTES) throw HostError.tooLarge
        val text = request.head.header("X-Offset")
        val offset = text?.takeIf { it.length <= 15 && it.isNotEmpty() && it.all { c -> c in '0'..'9' } }?.toLong() ?: throw HostError.badRequest
        val state = withContext(Dispatchers.IO) { inbox.write(guest.id, id, offset, length, request.body, request::abort) }
        return HostResponse.json(200, state)
    }

    private fun galleryCheck(request: HostRequest, now: Long): HostResponse {
        val guest = authenticate(request, now)
        val length = request.head.contentLength ?: throw HostError.lengthRequired
        if (length > MAX_GALLERY_BODY) throw HostError.tooLarge
        val ids = json<GalleryCheckRequest>(request.body.readAll()).ids
        if (ids.any { !isValidSourceId(it) }) throw HostError.badRequest
        if (ids.size > MAX_GALLERY_IDS) throw HostError.tooLarge
        return HostResponse.json(200, GalleryCheckReply(gallery.missing(guest.id, ids)))
    }

    private suspend fun outbox(request: HostRequest, now: Long): HostResponse {
        val guest = authenticate(request, now)
        var wait = 0
        HostHttp.queryParameters(request.head.query)["wait"]?.let { text ->
            if (text.isEmpty() || text.length > 6 || !text.all { it in '0'..'9' }) throw HostError.badRequest
            wait = text.toInt()
        }
        wait = minOf(wait, 25)
        // A guest that hangs up during the wait stops it here, so it does not hold a slot.
        val items = if (wait == 0) outbox.pending(guest.id) else request.whileConnected { outbox.await(guest.id, wait * 1000L) }
        val entries = ArrayList<OutboxEntry>()
        var inline = 0L
        for (item in items) {
            val bytes = (item.text?.toByteArray()?.size ?: 0) + (item.url?.toByteArray()?.size ?: 0)
            if (entries.isNotEmpty() && (entries.size >= MAX_REPLY_ITEMS || inline + bytes > MAX_REPLY_INLINE)) break
            entries.add(OutboxEntry(item.id, item.kind, item.text, item.url, item.name, item.size, item.mime))
            inline += bytes
        }
        return HostResponse.json(200, OutboxReply(entries, if (entries.size < items.size) true else null))
    }

    private fun outboxData(request: HostRequest, id: String, now: Long): HostResponse {
        val guest = authenticate(request, now)
        val item = outbox.find(guest.id, id)?.takeIf { it.kind == "file" && it.path != null } ?: throw HostError.notFound
        val file = File(item.path!!)
        val size = file.takeIf { it.isFile }?.length() ?: throw HostError.notFound
        if (item.size != null && item.size != size) throw HostError.changed
        val range = request.head.header("Range")
        var partial = range != null
        // Only "bytes=n-" is understood: a download resumed where it broke.
        val start = if (range == null) 0L else range.removePrefix("bytes=").removeSuffix("-").takeIf {
            range.startsWith("bytes=") && range.endsWith('-') && range.length in 8..22 && it.all { c -> c in '0'..'9' }
        }?.toLong() ?: return HostResponse.error(HostError.rangeNotSatisfiable, "Content-Range" to "bytes */$size")
        if (size == 0L) partial = false
        if (size > 0 && start >= size) {
            return HostResponse.error(HostError.rangeNotSatisfiable, "Content-Range" to "bytes */$size")
        }
        val stream = try {
            file.inputStream().also { it.channel.position(start) }
        } catch (e: FileNotFoundException) {
            throw HostError.notFound
        }
        val headers = listOf("Content-Type" to (item.mime ?: "application/octet-stream"), "Accept-Ranges" to "bytes")
        if (!partial) return HostResponse(200, headers, stream = stream, length = size)
        return HostResponse(206, headers + ("Content-Range" to "bytes $start-${size - 1}/$size"), stream = stream, length = size - start)
    }

    private fun acknowledge(request: HostRequest, id: String, now: Long): HostResponse {
        val guest = authenticate(request, now)
        outbox.acknowledge(guest.id, id)?.let(onAcknowledged)
        return HostResponse.empty(204)
    }

    private inline fun <reified T> json(bytes: ByteArray): T = try {
        LinkJson.decodeFromString<T>(String(bytes, Charsets.UTF_8))
    } catch (e: IllegalArgumentException) {
        throw HostError.badRequest
    }
}
