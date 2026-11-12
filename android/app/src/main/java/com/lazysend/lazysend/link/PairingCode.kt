package com.lazysend.lazysend.link

import java.io.ByteArrayOutputStream

enum class PairingCodeProblem { NotPairingCode, NewerVersion, Damaged }

class PairingCodeException(val problem: PairingCodeProblem, message: String) : Exception(message)

/** What the PC's QR code carries: `lazysend://pair?v=1&id=&n=&fp=&a=&p=&t=`. */
data class PairingCode(
    val desktopId: String,
    val name: String,
    val fingerprint: String,
    val addresses: List<String>,
    val port: Int,
    val token: String,
) {
    val pin: ByteArray get() = decodeBase64Url(fingerprint)!!

    /** The six digits the PC shows as well, so the person can see both ends hold the same key. */
    val checkCode: String
        get() {
            val value = pin.take(4).fold(0L) { acc, b -> (acc shl 8) or (b.toLong() and 0xFF) } % 1_000_000
            return "%06d".format(value).let { "${it.take(3)} ${it.drop(3)}" }
        }

    companion object {
        private const val PREFIX = "lazysend://pair?"
        private const val MAX_LENGTH = 2048

        fun parse(text: String): PairingCode {
            val code = text.trim()
            if (!code.startsWith("lazysend:", ignoreCase = true)) {
                throw PairingCodeException(PairingCodeProblem.NotPairingCode, "This is not a Lazy Send pairing code.")
            }
            if (code.length > MAX_LENGTH || !code.startsWith(PREFIX, ignoreCase = true) || code.any { it <= ' ' || it > '~' } || '#' in code) {
                throw damaged()
            }
            val raw = HashMap<String, String>()
            for (part in code.substring(PREFIX.length).split('&')) {
                if (part.isEmpty()) continue
                val eq = part.indexOf('=')
                val key = if (eq < 0) part else part.substring(0, eq)
                val value = if (eq < 0) "" else part.substring(eq + 1)
                if (key.isEmpty() || percentDecode(value) == null || raw.put(key, value) != null) throw damaged()
            }
            fun value(key: String) = raw[key]?.let(::percentDecode)

            val version = value("v")?.toIntOrNull() ?: throw damaged()
            if (version > PROTOCOL_VERSION) {
                throw PairingCodeException(
                    PairingCodeProblem.NewerVersion,
                    "This pairing code is from a newer version of Lazy Send. Update the app on this phone, then scan it again.",
                )
            }
            if (version < 1) throw damaged()
            val id = value("id") ?: throw damaged()
            val name = value("n") ?: throw damaged()
            val fp = value("fp") ?: throw damaged()
            val port = value("p")?.toIntOrNull() ?: throw damaged()
            val token = value("t") ?: throw damaged()
            val addresses = raw["a"]?.takeIf { it.isNotEmpty() }?.split(',')?.map { percentDecode(it) ?: throw damaged() } ?: emptyList()
            if (decodeBase64Url(fp)?.size != 32 || port !in 1..65535 || decodeBase64Url(token)?.size != 16) throw damaged()
            return PairingCode(id, name, fp, addresses, port, token)
        }

        private fun damaged() = PairingCodeException(
            PairingCodeProblem.Damaged,
            "This pairing code could not be read. Show the code on the computer again and scan it once more.",
        )
    }
}

fun percentDecode(text: String): String? {
    val bytes = ByteArrayOutputStream()
    var i = 0
    while (i < text.length) {
        val c = text[i]
        if (c == '%') {
            val hex = text.substring(i + 1, minOf(i + 3, text.length))
            if (hex.length < 2 || hex.any { Character.digit(it, 16) < 0 }) return null
            bytes.write(hex.toInt(16))
            i += 3
        } else {
            bytes.write(c.code)
            i++
        }
    }
    return bytes.toString(Charsets.UTF_8)
}

fun encodeBase64Url(data: ByteArray): String = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(data)

fun decodeBase64Url(text: String): ByteArray? = try {
    java.util.Base64.getUrlDecoder().decode(text).takeIf { encodeBase64Url(it) == text }
} catch (e: IllegalArgumentException) {
    null
}
