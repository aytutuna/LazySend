package com.lazysend.lazysend.host

import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HostNetworksTest {
    private fun ip(text: String) = InetAddress.getByName(text)

    private val networks = HostNetworks({
        listOf(
            HostSubnet("wlan0", ip("192.168.1.20"), 24),
            HostSubnet("rndis0", ip("169.254.10.2"), 16),
            HostSubnet("swlan0", ip("fd00::20"), 64),
            HostSubnet("ap0", ip("100.64.3.1"), 24),
            HostSubnet("wlan0", ip("fe80::1"), 64),
            HostSubnet("eth0", ip("10.0.0.7"), 8),
        )
    })

    @Test
    fun onlyWifiWiredTetherAndHotspotInterfacesHost() {
        for (name in listOf("wlan0", "wlan1", "eth0", "rndis0", "usb0", "ncm0", "ap0", "swlan0", "p2p-wlan0-0")) assertTrue(name, HostNetworks.isHostInterface(name))
        for (name in listOf("rmnet_data0", "rmnet0", "ccmni1", "v4-rmnet_data1", "pdp0", "tun0", "dummy0", "lo")) assertFalse(name, HostNetworks.isHostInterface(name))
    }

    @Test
    fun connectionsOnCellularAddressesAreRefused() {
        assertTrue(networks.allowsLocal(ip("192.168.1.20")))
        assertTrue(networks.allowsLocal(ip("127.0.0.1")))
        assertFalse(networks.allowsLocal(ip("10.55.1.9")))
        assertFalse(networks.allowsLocal(ip("2607:f8b0::1")))
    }

    @Test
    fun peersFromPrivateRangesAndOwnSubnetsAreAnswered() {
        for (peer in listOf("192.168.1.5", "10.1.2.3", "172.20.10.2", "172.16.0.1", "169.254.4.4", "fe80::5", "fd12::9", "127.0.0.1", "100.64.3.9")) {
            assertTrue(peer, networks.allowsPeer(ip(peer)))
        }
        for (peer in listOf("8.8.8.8", "172.32.0.1", "100.100.5.5", "2607:f8b0::1", "11.0.0.1")) assertFalse(peer, networks.allowsPeer(ip(peer)))
    }

    @Test
    fun pairingAddressesListIpv4FirstSelfAssignedLastAndNoLinkLocalIpv6() {
        assertEquals(listOf("192.168.1.20", "100.64.3.1", "10.0.0.7", "169.254.10.2", "fd00:0:0:0:0:0:0:20"), networks.pairingAddresses())
    }
}
