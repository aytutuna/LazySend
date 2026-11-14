package com.lazysend.lazysend.host

import com.lazysend.lazysend.link.PairingCode
import org.junit.Assert.assertEquals
import org.junit.Test

class PairingLinkTest {
    @Test
    fun theGuestsParserReadsWhatTheHostWrites() {
        val fingerprint = ByteArray(32) { it.toByte() }
        val session = PairingSession(0)
        val text = pairingLink("host-test-0001", "Pixel 9 & ñ", fingerprint, listOf("192.168.1.5", "fd00:0:0:0:0:0:0:20"), 52734, session.tokenText)
        val code = PairingCode.parse(text)
        assertEquals("host-test-0001", code.desktopId)
        assertEquals("Pixel 9 & ñ", code.name)
        assertEquals(listOf("192.168.1.5", "fd00:0:0:0:0:0:0:20"), code.addresses)
        assertEquals(52734, code.port)
        assertEquals(session.tokenText, code.token)
        assertEquals("066 051", code.checkCode)
    }
}
