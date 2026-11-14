package com.lazysend.lazysend.host

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HostAdvertiserTest {
    @Test
    fun theInstanceNameFitsADnsLabel() {
        val name = HostAdvertiser.serviceName("é".repeat(60))
        assertTrue(name.toByteArray().size <= 63)
        assertEquals("Lazy Send", HostAdvertiser.serviceName("  "))
        assertEquals("Pixel 9", HostAdvertiser.serviceName("Pixel 9"))
    }
}
