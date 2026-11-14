package com.lazysend.lazysend.host

import com.lazysend.lazysend.link.ApiError
import com.lazysend.lazysend.link.LinkJson
import java.io.EOFException
import java.io.InputStream
import kotlinx.serialization.encodeToString

/** An error answer: a status and one of the stable codes in CONTRACTS.md. */
class HostError(val status: Int, val code: String, message: String, val offset: Long? = null) : Exception(message) {
    companion object {
        val unauthorized = HostError(401, "unauthorized", "This phone no longer recognizes this device. Pair it again.")
        val pairingClosed = HostError(403, "pairingClosed", "Pairing is not open on this phone. Open Receive there and scan the new code.")
        val tokenInvalid = HostError(403, "tokenInvalid", "This pairing code is not valid. Scan the code shown on the phone again.")
        val tokenExpired = HostError(403, "tokenExpired", "This pairing code has expired. Show a new code on the phone.")
        val tokenUsed = HostError(403, "tokenUsed", "This pairing code was already used. Show a new code on the phone.")
        val declined = HostError(403, "declined", "Pairing was declined on the phone.")
        val tooManyGuests = HostError(409, "tooManyDevices", "This phone is paired with $MAX_GUESTS devices already. Remove one there first.")
        val tooLarge = HostError(413, "tooLarge", "The request is larger than this phone takes.")
        val rateLimited = HostError(429, "rateLimited", "Too many attempts. Wait a minute, then try again.")
        val notFound = HostError(404, "notFound", "Not found.")
        val methodNotAllowed = HostError(405, "methodNotAllowed", "This address does not take that request.")
        val badRequest = HostError(400, "badRequest", "The request was not understood.")
        val lengthRequired = HostError(411, "lengthRequired", "The request must say how long it is (Content-Length).")
        val busy = HostError(409, "busy", "This file is still being received. Try again in a moment.")
        val hashMismatch = HostError(422, "hashMismatch", "The file arrived damaged. Send it again from the start.")
        val diskFull = HostError(507, "diskFull", "This phone is almost out of storage.")
        val rangeNotSatisfiable = HostError(416, "rangeNotSatisfiable", "That part of the file is not available.")
        val changed = HostError(409, "changed", "The file changed on the phone after it was queued.")
        val serverError = HostError(500, "serverError", "The phone could not store this.")

        fun offsetMismatch(offset: Long) =
            HostError(409, "offsetMismatch", "The file is not at that offset here. Continue from the offset given.", offset)
    }
}

class RequestHead(
    val method: String,
    val target: String,
    val headers: List<Pair<String, String>>,
    val contentLength: Long?,
    val expectsContinue: Boolean,
) {
    val path: String get() = target.substringBefore('?')
    val query: String get() = if ('?' in target) target.substringAfter('?') else ""

    fun header(name: String): String? = headers.firstOrNull { it.first.equals(name, ignoreCase = true) }?.second

    val bearer: String?
        get() = header("Authorization")?.takeIf { it.startsWith("Bearer ", ignoreCase = true) }?.substring(7)?.trim()
}

sealed interface Parsed {
    data object Incomplete : Parsed
    class Complete(val head: RequestHead, val consumed: Int) : Parsed
    class Invalid(val status: Int) : Parsed
}

/**
 * The small part of HTTP/1.1 the phone link uses, read strictly: one request per connection (every answer closes), GET, PUT,
 * POST or DELETE with an origin-form target and version HTTP/1.1, CRLF line ends only, no folded headers, at most 64 headers
 * in 16 KiB, a Host header, a body only by one plain Content-Length (any Transfer-Encoding is refused, chunked included)
 * and `Expect: 100-continue` as the only expectation.
 */
object HostHttp {
    const val MAX_REQUEST_LINE = 2048
    const val MAX_HEAD = 16 * 1024
    const val MAX_HEADERS = 64
    private val methods = listOf("GET", "PUT", "POST", "DELETE")
    val continueResponse = "HTTP/1.1 100 Continue\r\n\r\n".toByteArray(Charsets.US_ASCII)

    fun parse(data: ByteArray, length: Int): Parsed {
        var lineStart = 0
        val lines = ArrayList<String>()
        var i = 0
        while (i < length) {
            val b = data[i]
            if (b == '\n'.code.toByte()) return Parsed.Invalid(400)
            if (b != '\r'.code.toByte()) {
                i++
                continue
            }
            if (i + 1 >= length) break
            if (data[i + 1] != '\n'.code.toByte()) return Parsed.Invalid(400)
            if (lines.isEmpty() && i - lineStart > MAX_REQUEST_LINE) return Parsed.Invalid(414)
            if (i + 2 > MAX_HEAD) return Parsed.Invalid(431)
            if (i == lineStart) return if (lines.isEmpty()) Parsed.Invalid(400) else head(lines, i + 2)
            if (lines.size > MAX_HEADERS) return Parsed.Invalid(431)
            lines.add(String(data, lineStart, i - lineStart, Charsets.ISO_8859_1))
            lineStart = i + 2
            i += 2
        }
        if (lines.isEmpty() && length - lineStart > MAX_REQUEST_LINE) return Parsed.Invalid(414)
        if (length >= MAX_HEAD) return Parsed.Invalid(431)
        return Parsed.Incomplete
    }

    private fun head(lines: List<String>, consumed: Int): Parsed {
        val parts = lines[0].split(' ')
        if (parts.size != 3) return Parsed.Invalid(400)
        val (method, target, version) = parts
        if (method.isEmpty() || !method.all(::isTokenChar)) return Parsed.Invalid(400)
        if (method !in methods) return Parsed.Invalid(501)
        if (version != "HTTP/1.1") {
            return if (Regex("HTTP/\\d\\.\\d").matches(version)) Parsed.Invalid(505) else Parsed.Invalid(400)
        }
        if (target.isEmpty() || target[0] != '/' || target.any { it <= ' ' || it >= '\u007F' || it == '#' }) return Parsed.Invalid(400)

        val headers = ArrayList<Pair<String, String>>(lines.size - 1)
        var contentLength: Long? = null
        var expectsContinue = false
        var hasHost = false
        for (line in lines.drop(1)) {
            if (line[0] == ' ' || line[0] == '\t') return Parsed.Invalid(400)
            val colon = line.indexOf(':')
            if (colon <= 0) return Parsed.Invalid(400)
            val name = line.substring(0, colon)
            if (!name.all(::isTokenChar)) return Parsed.Invalid(400)
            val value = line.substring(colon + 1).trim(' ', '\t')
            if (value.any { it != '\t' && (it < ' ' || it >= '\u007F') }) return Parsed.Invalid(400)
            headers.add(name to value)
            when {
                name.equals("Content-Length", true) -> {
                    if (contentLength != null || value.isEmpty() || value.length > 15 || !value.all { it in '0'..'9' }) return Parsed.Invalid(400)
                    contentLength = value.toLong()
                }
                name.equals("Transfer-Encoding", true) -> return Parsed.Invalid(501)
                name.equals("Host", true) -> {
                    if (hasHost) return Parsed.Invalid(400)
                    hasHost = true
                }
                name.equals("Expect", true) -> {
                    if (!value.equals("100-continue", true)) return Parsed.Invalid(417)
                    expectsContinue = true
                }
            }
        }
        if (!hasHost) return Parsed.Invalid(400)
        return Parsed.Complete(RequestHead(method, target, headers, contentLength, expectsContinue), consumed)
    }

    private fun isTokenChar(c: Char) = c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c in "!#$%&'*+-.^_`|~"

    fun reason(status: Int) = when (status) {
        100 -> "Continue"
        200 -> "OK"
        201 -> "Created"
        204 -> "No Content"
        206 -> "Partial Content"
        400 -> "Bad Request"
        401 -> "Unauthorized"
        403 -> "Forbidden"
        404 -> "Not Found"
        405 -> "Method Not Allowed"
        408 -> "Request Timeout"
        409 -> "Conflict"
        411 -> "Length Required"
        413 -> "Content Too Large"
        414 -> "URI Too Long"
        416 -> "Range Not Satisfiable"
        417 -> "Expectation Failed"
        422 -> "Unprocessable Content"
        429 -> "Too Many Requests"
        431 -> "Request Header Fields Too Large"
        500 -> "Internal Server Error"
        501 -> "Not Implemented"
        503 -> "Service Unavailable"
        505 -> "HTTP Version Not Supported"
        507 -> "Insufficient Storage"
        else -> "Unknown"
    }

    /** The status line, [headers], Content-Length and `Connection: close`, and the blank line. */
    fun responseHead(status: Int, headers: List<Pair<String, String>>, contentLength: Long): ByteArray {
        val text = StringBuilder("HTTP/1.1 $status ${reason(status)}\r\n")
        for ((name, value) in headers) text.append(name).append(": ").append(value).append("\r\n")
        text.append("Content-Length: $contentLength\r\nConnection: close\r\n\r\n")
        return text.toString().toByteArray(Charsets.US_ASCII)
    }

    /** A query's parameters, the first value of each name, as sent. */
    fun queryParameters(query: String): Map<String, String> {
        val values = LinkedHashMap<String, String>()
        for (part in query.split('&')) {
            if (part.isEmpty()) continue
            val eq = part.indexOf('=')
            values.putIfAbsent(if (eq < 0) part else part.substring(0, eq), if (eq < 0) "" else part.substring(eq + 1))
        }
        return values
    }
}

/**
 * A request's body: exactly its Content-Length bytes of the connection. A client that sent `Expect: 100-continue` is told to
 * go on when the first byte is asked for. A connection that ends early throws [EOFException].
 */
class RequestBody(
    private val input: InputStream,
    val length: Long,
    private val buffered: ByteArray = ByteArray(0),
    private val sendContinue: (() -> Unit)? = null,
) : InputStream() {
    private var bufferedUsed = 0
    var remaining = length
        private set
    private var started = false

    /** The client is holding its body back until it is told to go on, so there is nothing to read and drop. */
    val isWithheld: Boolean get() = sendContinue != null && !started

    override fun read(): Int {
        val one = ByteArray(1)
        return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xFF
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (remaining == 0L) return -1
        if (len == 0) return 0
        if (!started) {
            started = true
            sendContinue?.invoke()
        }
        val want = minOf(len.toLong(), remaining).toInt()
        val n = if (bufferedUsed < buffered.size) {
            val take = minOf(want, buffered.size - bufferedUsed)
            System.arraycopy(buffered, bufferedUsed, b, off, take)
            bufferedUsed += take
            take
        } else {
            input.read(b, off, want)
        }
        if (n < 0) throw EOFException("The connection ended before the body did.")
        remaining -= n
        return n
    }

    /** Reads and drops up to [max] of what is left of the body. */
    fun discard(max: Long = remaining) {
        if (isWithheld) return
        val buffer = ByteArray(8192)
        var left = minOf(max, remaining)
        while (left > 0) left -= read(buffer, 0, minOf(buffer.size.toLong(), left).toInt())
    }

    /** The whole body (small ones only). */
    fun readAll(): ByteArray {
        val bytes = ByteArray(length.toInt())
        var filled = 0
        while (filled < bytes.size) filled += read(bytes, filled, bytes.size - filled)
        return bytes
    }
}

class HostResponse(
    val status: Int,
    val headers: List<Pair<String, String>> = emptyList(),
    val body: ByteArray = ByteArray(0),
    val stream: InputStream? = null,
    val length: Long = body.size.toLong(),
    /** Called with whether the answer was written, so a pairing can be undone when the guest never got its secret. */
    val written: ((Boolean) -> Unit)? = null,
) {
    fun withWritten(callback: (Boolean) -> Unit) = HostResponse(status, headers, body, stream, length, callback)

    companion object {
        fun json(status: Int, text: String) = HostResponse(status, listOf("Content-Type" to JSON), text.toByteArray())

        inline fun <reified T> json(status: Int, value: T) = json(status, LinkJson.encodeToString(value))

        fun error(e: HostError, vararg headers: Pair<String, String>) = HostResponse(
            e.status, listOf("Content-Type" to JSON) + headers, LinkJson.encodeToString(ApiError(e.code, e.message.orEmpty(), e.offset)).toByteArray(),
        )

        fun empty(status: Int) = HostResponse(status)

        const val JSON = "application/json; charset=utf-8"
    }
}

