package com.lazysend.lazysend.host

import java.io.File
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HostIdentityTest {
    private val keys = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    private val file = File.createTempFile("cert", ".der")
    private val year = 365L * 24 * 60 * 60 * 1000
    private var now = 1_760_000_000_000L
    private val identity = HostIdentity(file, keys.private, keys.public, { "Pixel" }, { now })

    @Test
    fun certificateIsSignedByTheKeyAndKeepsItsPublicKey() {
        val cert = identity.certificate()
        cert.verify(keys.public)
        assertArrayEquals(keys.public.encoded, cert.publicKey.encoded)
        assertArrayEquals(sha256(keys.public.encoded), identity.fingerprint)
        assertEquals("CN=Pixel Lazy Send", cert.subjectX500Principal.name)
        assertTrue(cert.keyUsage[0])
        assertTrue(cert.extendedKeyUsage.contains("1.3.6.1.5.5.7.3.1"))
    }

    @Test
    fun keptCertificateIsReusedAndRenewedOnTheSameKey() {
        val first = identity.certificate()
        assertArrayEquals(first.encoded, identity.certificate().encoded)
        now += 9 * year + year * 9 / 10
        val renewed = identity.certificate()
        assertFalse(first.encoded.contentEquals(renewed.encoded))
        assertTrue(renewed.notAfter.time > now + 9 * year)
        assertArrayEquals(first.publicKey.encoded, renewed.publicKey.encoded)
        assertArrayEquals(identity.fingerprint, sha256(renewed.publicKey.encoded))
    }

    @Test
    fun aCertificateOfAnotherKeyIsReplaced() {
        val other = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        HostIdentity(file, other.private, other.public, { "Other" }, { now }).certificate()
        val cert = identity.certificate()
        assertArrayEquals(keys.public.encoded, cert.publicKey.encoded)
        assertNotEquals("CN=Other Lazy Send", cert.subjectX500Principal.name)
    }
}
