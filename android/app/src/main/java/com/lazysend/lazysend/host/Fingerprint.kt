package com.lazysend.lazysend.host

/** The six digits both screens show, so a person can see the guest met the key the host holds. */
object Fingerprint {
    /** The first four bytes as a big-endian number modulo one million; "" for fewer than four bytes. */
    fun checkCode(fingerprint: ByteArray): String {
        if (fingerprint.size < 4) return ""
        val value = fingerprint.take(4).fold(0L) { acc, b -> (acc shl 8) or (b.toLong() and 0xFF) } % 1_000_000
        return "%06d".format(value)
    }

    /** The same digits taken from SHA-256 over the fingerprint and the canonical short code, which cannot be ground in advance. */
    fun matchCode(fingerprint: ByteArray, shortCode: String): String {
        if (fingerprint.size != 32) return ""
        return checkCode(sha256(fingerprint + shortCode.toByteArray(Charsets.US_ASCII)))
    }

    fun spaced(digits: String): String = if (digits.length == 6) "${digits.take(3)} ${digits.drop(3)}" else digits
}
