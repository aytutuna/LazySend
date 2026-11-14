package com.lazysend.lazysend.host

import com.lazysend.lazysend.link.PROTOCOL_VERSION
import com.lazysend.lazysend.link.encodeBase64Url
import java.net.URLEncoder

/** The text of the QR code: `lazysend://pair?v=1&id=&n=&fp=&a=&p=&t=`. */
fun pairingLink(id: String, name: String, fingerprint: ByteArray, addresses: List<String>, port: Int, token: String): String {
    fun enc(text: String) = URLEncoder.encode(text, "UTF-8").replace("+", "%20")
    return "lazysend://pair?v=$PROTOCOL_VERSION&id=${enc(id)}&n=${enc(name)}&fp=${encodeBase64Url(fingerprint)}" +
        "&a=${addresses.take(8).joinToString(",") { enc(it) }}&p=$port&t=$token"
}
