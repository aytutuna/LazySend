package com.lazysend.lazysend.transfer

import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

enum class LinkKind(val label: String) {
    WiFi("Wi-Fi"),
    Usb("USB"),
    Hotspot("Hotspot"),
    Other("Network"),
}

/** An IPv4 address of this phone on the interface [name]. */
data class Subnet(val name: String, val address: Int, val prefix: Int) {
    fun contains(host: Int): Boolean {
        val mask = if (prefix == 0) 0 else -1 shl (32 - prefix)
        return (address and mask) == (host and mask)
    }

    fun kind(): LinkKind {
        val n = name.lowercase()
        return when {
            n.startsWith("rndis") || n.startsWith("usb") || n.startsWith("ncm") -> LinkKind.Usb
            n.startsWith("ap") || n.startsWith("swlan") || n.startsWith("softap") -> LinkKind.Hotspot
            n.startsWith("wlan") || n.startsWith("wifi") -> LinkKind.WiFi
            else -> LinkKind.Other
        }
    }
}

fun ipv4ToInt(text: String): Int? {
    val parts = text.split('.')
    if (parts.size != 4) return null
    var value = 0
    for (part in parts) {
        val n = part.toIntOrNull() ?: return null
        if (n !in 0..255) return null
        value = (value shl 8) or n
    }
    return value
}

fun intToIpv4(value: Int) = "${value ushr 24 and 255}.${value ushr 16 and 255}.${value ushr 8 and 255}.${value and 255}"

/** Which kind of link carries [host], from the interface of this phone whose network it is on. */
fun linkKindFor(host: String, subnets: List<Subnet>): LinkKind {
    val address = ipv4ToInt(host) ?: return LinkKind.Other
    return subnets.firstOrNull { it.contains(address) }?.kind() ?: LinkKind.Other
}

fun localSubnets(): List<Subnet> = try {
    NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }.flatMap { nif ->
        nif.interfaceAddresses.mapNotNull { ia ->
            (ia.address as? Inet4Address)?.let { Subnet(nif.name, ipv4ToInt(it.hostAddress!!) ?: return@mapNotNull null, ia.networkPrefixLength.toInt()) }
        }
    }
} catch (e: java.net.SocketException) {
    emptyList()
}

/**
 * Hosts on this phone's own networks (up to a /24 around each address) that accept a connection on
 * [port]; the way to find a PC on a USB tether or a hotspot, where nothing announces it.
 */
suspend fun probeSubnets(port: Int, subnets: List<Subnet> = localSubnets(), timeoutMs: Int = 400): List<String> = coroutineScope {
    val candidates = subnets.flatMap { s ->
        val prefix = maxOf(s.prefix, 24)
        val base = s.address and (-1 shl (32 - prefix))
        (1 until (1 shl (32 - prefix)) - 1).map { base + it }.filter { it != s.address }
    }.distinct()
    val limit = Semaphore(64)
    candidates.map { host ->
        async(Dispatchers.IO) {
            limit.withPermit {
                val text = intToIpv4(host)
                try {
                    Socket().use { it.connect(InetSocketAddress(InetAddress.getByName(text), port), timeoutMs) }
                    text
                } catch (e: java.io.IOException) {
                    null
                }
            }
        }
    }.awaitAll().filterNotNull()
}
