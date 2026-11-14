package com.lazysend.lazysend.host

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class PairingTest {
    private val fingerprint = ByteArray(32) { it.toByte() }

    @Test
    fun sharedVectors() {
        assertEquals("066 051", Fingerprint.spaced(Fingerprint.checkCode(fingerprint)))
        assertEquals("987 292", Fingerprint.spaced(Fingerprint.matchCode(fingerprint, "7KQ2M9XD")))
    }

    @Test
    fun shortCodeFolding() {
        assertEquals("7KQ2M9XD", PairingSession.normalizeShortCode("7kq2-m9xd"))
        assertEquals("7KQ2M9XD", PairingSession.normalizeShortCode(" 7KQ2 M9XD "))
        assertNull(PairingSession.normalizeShortCode("7KQ2M9XI"))
        assertNull(PairingSession.normalizeShortCode("7KQ2M9X"))
    }

    @Test
    fun tokenAndShortCodeUseTheSessionOnce() {
        val session = PairingSession(0)
        assertEquals(Redeem.Accepted, session.redeem(session.tokenText, 1000, "a"))
        assertEquals(Redeem.AlreadyUsed, session.redeem(session.shortCode, 1000, "a"))
        val other = PairingSession(0)
        assertEquals(Redeem.Accepted, other.redeem(other.shortCodeText.lowercase(), 1000, "a"))
        assertEquals(Redeem.AlreadyUsed, other.redeem(other.tokenText, 1000, "a"))
    }

    @Test
    fun expiresAfterFiveMinutes() {
        val session = PairingSession(0)
        assertEquals(SessionState.Open, session.stateAt(PairingSession.LIFETIME_MS - 1))
        assertEquals(Redeem.Expired, session.redeem(session.tokenText, PairingSession.LIFETIME_MS, "a"))
    }

    @Test
    fun fiveWrongOnesRefuseThePeerAndTwentyFiveCloseTheSession() {
        val session = PairingSession(0)
        repeat(5) { assertEquals(Redeem.WrongToken, session.redeem("AAAAAAAA", 10, "a")) }
        assertEquals(Redeem.Closed, session.redeem(session.tokenText, 10, "a"))
        for (peer in 0 until 4) repeat(5) { session.redeem("AAAAAAAA", 10, "p$peer") }
        assertEquals(Redeem.Closed, session.redeem(session.tokenText, 10, "fresh"))
    }

    @Test
    fun guestsKeepOnlyTheSecretHash() {
        val file = File.createTempFile("guests", ".json")
        val store = GuestStore(file)
        val secret = store.pair("phone-0001", "Pixel", "android", "1.0", 1000)
        assertFalse(file.readText().contains(secret))
        assertNotNull(store.authenticate("phone-0001", secret, 2000))
        assertNull(store.authenticate("phone-0001", secret.reversed(), 2000))
        assertNull(store.authenticate("phone-0002", secret, 2000))
        assertNotNull(GuestStore(file).authenticate("phone-0001", secret, 3000))
        val again = store.pair("phone-0001", "Pixel", "android", "1.0", 4000)
        assertNull(store.authenticate("phone-0001", secret, 5000))
        assertNotNull(store.authenticate("phone-0001", again, 5000))
        assertTrue(store.remove("phone-0001"))
        assertNull(store.authenticate("phone-0001", again, 6000))
    }

    @Test
    fun seventeenthGuestIsRefusedButARepairingOneIsNot() {
        val store = GuestStore(File.createTempFile("guests", ".json"))
        repeat(16) { store.pair("phone-%04d".format(it), "p", "android", "1", 0) }
        try {
            store.pair("phone-9999", "p", "android", "1", 0)
            fail()
        } catch (e: TooManyGuests) {
        }
        store.pair("phone-0003", "p", "android", "1", 0)
        assertEquals(16, store.guests.value.size)
    }

    @Test
    fun rateLimiterBlocksAfterTenFailures() {
        val limiter = RateLimiter()
        repeat(10) { limiter.recordFailure("a", 100) }
        assertTrue(limiter.isBlocked("a", 200))
        assertFalse(limiter.tryRequest("a", 200))
        assertFalse(limiter.isBlocked("a", 100 + RateLimiter.WINDOW_MS))
        assertTrue(limiter.tryRequest("b", 200))
    }
}
