package com.lazysend.lazysend.host

import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.SocketException

/** An address of this phone on one of the interfaces it hosts on, with the length of its prefix. */
data class HostSubnet(val name: String, val address: InetAddress, val prefix: Int) {
    fun contains(other: InetAddress): Boolean {
        val a = address.address
        val b = other.address
        if (a.size != b.size) return false
        var bits = prefix.coerceIn(0, a.size * 8)
        var i = 0
        while (bits > 0) {
            val mask = if (bits >= 8) 0xFF else (0xFF shl (8 - bits)) and 0xFF
            if ((a[i].toInt() and mask) != (b[i].toInt() and mask)) return false
            i++
            bits -= 8
        }
        return true
    }
}

/**
 * Where the host listens and whom it answers. A phone hosts on Wi-Fi, Ethernet, USB tethering and hotspot interfaces only,
 * never on the mobile network (rmnet, ccmni and the like), and answers peers from private, link-local and unique-local
 * ranges or from the subnet of one of those interfaces. Read again at most every few seconds because every connection asks.
 */
class HostNetworks(
    private val read: () -> List<HostSubnet> = ::currentSubnets,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private var cached = emptyList<HostSubnet>()
    private var readAt = Long.MIN_VALUE / 2

    @Synchronized
    fun subnets(): List<HostSubnet> {
        val now = clock()
        if (now - readAt > CACHE_MS) {
            cached = read()
            readAt = now
        }
        return cached
    }

    /** Whether a connection that arrived on [local] came in on a host interface (or loopback). */
    fun allowsLocal(local: InetAddress): Boolean = local.isLoopbackAddress || subnets().any { it.address == local }

    fun allowsPeer(remote: InetAddress): Boolean = isLocalAddress(remote) || subnets().any { it.contains(remote) }

    /** IPv4 first, self-assigned 169.254.x.x last of those, then IPv6; at most eight. */
    fun pairingAddresses(): List<String> {
        val all = subnets().map { it.address }.filter { !it.isLinkLocalAddress || isSelfAssigned(it) }.distinct()
        val v4 = all.filterIsInstance<Inet4Address>().sortedBy { isSelfAssigned(it) }
        val v6 = all.filter { it !is Inet4Address }
        return (v4 + v6).take(8).map { it.hostAddress!!.substringBefore('%') }
    }

    private fun isSelfAssigned(address: InetAddress) = address is Inet4Address && address.address.let { it[0] == 169.toByte() && it[1] == 254.toByte() }

    companion object {
        private const val CACHE_MS = 5000L
        private val PREFIXES = listOf("wlan", "wifi", "p2p", "ap", "swlan", "softap", "rndis", "usb", "ncm", "eth")

        fun isHostInterface(name: String): Boolean = name.lowercase().let { n -> PREFIXES.any { n.startsWith(it) } }

        /** Loopback, RFC 1918, link-local and unique-local. The shared 100.64.0.0/10 range counts only as an own subnet. */
        fun isLocalAddress(address: InetAddress): Boolean {
            if (address.isLoopbackAddress) return true
            val b = address.address
            if (address is Inet4Address) {
                val first = b[0].toInt() and 0xFF
                val second = b[1].toInt() and 0xFF
                return first == 10 || (first == 172 && second and 0xF0 == 16) || (first == 192 && second == 168) || (first == 169 && second == 254)
            }
            return (b[0].toInt() and 0xFF == 0xFE && b[1].toInt() and 0xC0 == 0x80) || (b[0].toInt() and 0xFE) == 0xFC
        }

        fun currentSubnets(): List<HostSubnet> = try {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback && isHostInterface(it.name) }
                .flatMap { nif -> nif.interfaceAddresses.map { HostSubnet(nif.name, it.address, it.networkPrefixLength.toInt()) } }
                .filter { !it.address.isMulticastAddress }
        } catch (e: SocketException) {
            emptyList()
        }
    }
}
