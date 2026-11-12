package com.lazysend.lazysend.transfer

import com.lazysend.lazysend.data.Pc
import com.lazysend.lazysend.data.PcStore
import com.lazysend.lazysend.link.FakePc
import com.lazysend.lazysend.link.TEST_SECRET
import com.lazysend.lazysend.link.encodeBase64Url
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PcConnectorTest {
    private val pc = FakePc()
    private val dir = File.createTempFile("connector", "").also { it.delete(); it.mkdirs() }
    private val store = PcStore(File(dir, "pcs.json"), { it }, { it })

    @After
    fun stop() {
        pc.close()
        dir.deleteRecursively()
    }

    @Test
    fun addressesTheComputerReportsComeFirst() = runBlocking {
        val old = (1..8).map { "10.9.9.$it" }
        store.put(Pc("desktop-test-01", "Test PC", encodeBase64Url(pc.pin), listOf(pc.endpoint.host) + old, pc.endpoint.port, TEST_SECRET))

        val result = PcConnector(store, null).connect(store.get("desktop-test-01")!!, search = false)

        assertTrue(result is Reach.Reached)
        val kept = store.get("desktop-test-01")!!.addresses
        assertEquals("192.168.42.10", kept.first())
        assertEquals(8, kept.size)
        assertEquals(pc.endpoint.host, store.get("desktop-test-01")!!.lastAddress)
    }

    @Test
    fun onlyLocalInterfacesAreProbed() {
        val address = ipv4ToInt("192.168.1.5")!!
        listOf("wlan0", "swlan0", "ap0", "rndis0", "usb0", "ncm0", "eth0").forEach { assertTrue(it, Subnet(it, address, 24).probeable()) }
        assertFalse(Subnet("rmnet_data1", address, 24).probeable())
        assertFalse(Subnet("tun0", address, 24).probeable())
        assertFalse(Subnet("dummy0", address, 24).probeable())
    }

    @Test
    fun linkKindComesFromTheInterfaceTheAddressIsOn() {
        val subnets = listOf(Subnet("wlan0", ipv4ToInt("192.168.1.20")!!, 24), Subnet("rndis0", ipv4ToInt("192.168.42.129")!!, 24))
        assertEquals(LinkKind.Usb, linkKindFor("192.168.42.10", subnets))
        assertEquals(LinkKind.WiFi, linkKindFor("192.168.1.7", subnets))
        assertEquals(LinkKind.Other, linkKindFor("10.0.0.1", subnets))
    }
}
