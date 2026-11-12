package com.lazysend.lazysend.link

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PairingCodeTest {
    private val fp = encodeBase64Url(ByteArray(32) { it.toByte() })
    private val token = encodeBase64Url(ByteArray(16) { (it + 1).toByte() })

    private fun code(extra: String = "", v: Int = 1) =
        "lazysend://pair?v=$v&id=desktop-0001&n=Aytu%27s%20PC&fp=$fp&a=192.168.1.5,192.168.42.10&p=52734&t=$token$extra"

    @Test
    fun readsEveryPart() {
        val parsed = PairingCode.parse(code())
        assertEquals("desktop-0001", parsed.desktopId)
        assertEquals("Aytu's PC", parsed.name)
        assertEquals(listOf("192.168.1.5", "192.168.42.10"), parsed.addresses)
        assertEquals(52734, parsed.port)
        assertEquals(32, parsed.pin.size)
    }

    @Test
    fun checkCodeIsTheFirstFourBytesModAMillion() {
        assertEquals("066 051", PairingCode.parse(code()).checkCode)
    }

    @Test
    fun ignoresUnknownParameters() {
        assertEquals(52734, PairingCode.parse(code("&x=1")).port)
    }

    @Test
    fun refusesOtherCodes() {
        val e = assertThrows(PairingCodeException::class.java) { PairingCode.parse("https://example.com") }
        assertEquals(PairingCodeProblem.NotPairingCode, e.problem)
    }

    @Test
    fun refusesANewerVersion() {
        val e = assertThrows(PairingCodeException::class.java) { PairingCode.parse(code(v = 2)) }
        assertEquals(PairingCodeProblem.NewerVersion, e.problem)
    }

    @Test
    fun refusesDamagedCodes() {
        assertThrows(PairingCodeException::class.java) { PairingCode.parse(code().replace("p=52734", "p=0")) }
        assertThrows(PairingCodeException::class.java) { PairingCode.parse(code().replace("fp=$fp", "fp=abc")) }
        assertThrows(PairingCodeException::class.java) { PairingCode.parse(code("&p=1")) }
    }
}
