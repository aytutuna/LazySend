package com.lazysend.lazysend.host

import com.lazysend.lazysend.link.decodeBase64Url
import com.lazysend.lazysend.link.encodeBase64Url
import java.security.MessageDigest

enum class SessionState { Open, Used, Expired, Closed }

enum class Redeem { Accepted, WrongToken, Expired, AlreadyUsed, Closed }

/**
 * One pairing window: a random 128-bit token for the QR code and an 8-character short code, good for one pairing within
 * five minutes. Both are compared in constant time; a peer with five wrong ones is refused for the rest of the session and
 * 25 wrong ones from anyone close it. Times are milliseconds, passed in so tests control them.
 */
class PairingSession(val opened: Long, private val token: ByteArray = ByteArray(16).also { random.nextBytes(it) }) {
    private var state = SessionState.Open
    private val failedByPeer = HashMap<String, Int>()
    private var failed = 0

    val tokenText: String = encodeBase64Url(token)
    val shortCode: String = String(CharArray(SHORT_CODE_LENGTH) { ALPHABET[random.nextInt(32)] })
    val shortCodeText: String get() = "${shortCode.take(4)}-${shortCode.drop(4)}"
    val expires: Long = opened + LIFETIME_MS

    @Synchronized
    fun stateAt(now: Long): SessionState = if (state == SessionState.Open && now >= expires) SessionState.Expired else state

    /** Presents [presented] from [peer]: the right one while the session is open is accepted once. */
    @Synchronized
    fun redeem(presented: String?, now: Long, peer: String): Redeem {
        when (state) {
            SessionState.Used -> return Redeem.AlreadyUsed
            SessionState.Closed -> return Redeem.Closed
            else -> Unit
        }
        if (now >= expires) {
            state = SessionState.Expired
            return Redeem.Expired
        }
        if (state == SessionState.Expired) return Redeem.Expired
        val byPeer = failedByPeer[peer] ?: 0
        if (byPeer >= MAX_PEER_FAILURES) return Redeem.Closed
        val bytes = presented?.let(::decodeBase64Url)
        var matches = bytes != null && bytes.size == token.size && MessageDigest.isEqual(bytes, token)
        normalizeShortCode(presented)?.let { matches = MessageDigest.isEqual(it.toByteArray(), shortCode.toByteArray()) }
        if (!matches) {
            failed++
            failedByPeer[peer] = byPeer + 1
            if (failed >= MAX_TOTAL_FAILURES) state = SessionState.Closed
            return Redeem.WrongToken
        }
        state = SessionState.Used
        return Redeem.Accepted
    }

    @Synchronized
    fun close() {
        if (state == SessionState.Open) state = SessionState.Closed
    }

    companion object {
        const val LIFETIME_MS = 5 * 60 * 1000L
        const val MAX_PEER_FAILURES = 5
        const val MAX_TOTAL_FAILURES = 25
        const val SHORT_CODE_LENGTH = 8
        private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

        /** A short code as typed (any case, dashes or spaces) in canonical form; null when it is not 8 characters of the alphabet. */
        fun normalizeShortCode(text: String?): String? {
            if (text == null || text.length > 32) return null
            val code = StringBuilder()
            for (c in text) {
                if (c == '-' || c == ' ') continue
                val upper = if (c in 'a'..'z') c - 32 else c
                if (ALPHABET.indexOf(upper) < 0) return null
                code.append(upper)
            }
            return code.takeIf { it.length == SHORT_CODE_LENGTH }?.toString()
        }
    }
}
