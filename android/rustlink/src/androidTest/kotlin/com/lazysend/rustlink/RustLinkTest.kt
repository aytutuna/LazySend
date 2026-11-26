package com.lazysend.rustlink

import android.security.keystore.KeyProperties
import android.security.keystore.KeyGenParameterSpec
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.lazy_link_ffi.AsyncSigner
import uniffi.lazy_link_ffi.InternalException
import uniffi.lazy_link_ffi.LinkException
import uniffi.lazy_link_ffi.PairingSession
import uniffi.lazy_link_ffi.Signer
import uniffi.lazy_link_ffi.checkCode
import uniffi.lazy_link_ffi.formatPairingCode
import uniffi.lazy_link_ffi.hashBytes
import uniffi.lazy_link_ffi.matchCode
import uniffi.lazy_link_ffi.normalizeShortCode
import uniffi.lazy_link_ffi.panicNow
import uniffi.lazy_link_ffi.parsePairingCode
import uniffi.lazy_link_ffi.patternBytes
import uniffi.lazy_link_ffi.signData
import uniffi.lazy_link_ffi.signDataAsync
import java.nio.ByteBuffer
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.util.Base64

@RunWith(AndroidJUnit4::class)
class RustLinkTest {
    private fun load(file: String): JsonElement {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        return Json.parseToJsonElement(assets.open(file).use { it.readBytes().decodeToString() })
    }

    private fun bytes(array: JsonArray) = ByteArray(array.size) { array[it].jsonPrimitive.int.toByte() }

    // Borrowed byte arguments cross as direct buffers, so Rust reads them where they are.
    private fun direct(data: ByteArray): ByteBuffer = ByteBuffer.allocateDirect(data.size).put(data).flip() as ByteBuffer

    private fun fromBase64Url(text: String): ByteArray = Base64.getUrlDecoder().decode(text)

    @Test
    fun pairingCodesAreReadAsTheDataSays() {
        for (case in load("pairing-uris.json").jsonObject["cases"]!!.jsonArray) {
            val c = case.jsonObject
            val name = c["name"]!!.jsonPrimitive.content
            val result = c["result"]!!.jsonPrimitive.content
            val uri = c["uri"]!!.jsonPrimitive.content
            if (result != "ok") {
                try {
                    parsePairingCode(uri)
                    fail("$name: expected $result")
                } catch (e: LinkException) {
                    assertEquals(name, result.lowercase(), e.javaClass.simpleName.lowercase())
                }
                continue
            }
            val code = parsePairingCode(uri)
            val want = c["pairing"]!!.jsonObject
            assertEquals(name, want["desktopId"]!!.jsonPrimitive.content, code.desktopId)
            assertEquals(name, want["name"]!!.jsonPrimitive.content, code.name)
            assertEquals(name, want["fingerprint"]!!.jsonPrimitive.content, code.fingerprint)
            assertEquals(name, want["port"]!!.jsonPrimitive.int, code.port.toInt())
            assertEquals(name, want["token"]!!.jsonPrimitive.content, code.token)
            assertEquals(name, want["addresses"]!!.jsonArray.map { it.jsonPrimitive.content }, code.addresses)
            assertEquals(name, want["checkCode"]!!.jsonPrimitive.content, checkCode(direct(fromBase64Url(code.fingerprint))))
            val written = formatPairingCode(code)
            assertEquals(name, written, formatPairingCode(parsePairingCode(written)))
        }
    }

    @Test
    fun checkCodesMatch() {
        for (case in load("check-codes.json").jsonObject["cases"]!!.jsonArray) {
            val c = case.jsonObject
            val fingerprint = bytes(c["fingerprint"]!!.jsonArray)
            assertEquals(c["checkCode"]!!.jsonPrimitive.content, checkCode(direct(fingerprint)))
            assertEquals(c["matchCode"]!!.jsonPrimitive.content, matchCode(direct(fingerprint), c["shortCode"]!!.jsonPrimitive.content))
        }
    }

    @Test
    fun shortCodesAreReadAndRedeemedAsTheDataSays() {
        val data = load("short-codes.json").jsonObject
        for (n in data["normalize"]!!.jsonArray) {
            val typed = n.jsonObject["typed"]!!
            if (typed is JsonNull) continue
            val canonical = n.jsonObject["canonical"]!!
            val expected = if (canonical is JsonNull) null else canonical.jsonPrimitive.content
            assertEquals(typed.jsonPrimitive.content, expected, normalizeShortCode(typed.jsonPrimitive.content))
        }
        val token = bytes(data["tokenBytes"]!!.jsonArray)
        for (r in data["redeem"]!!.jsonArray) {
            val session = PairingSession(0L, token, byteArrayOf(7, 3, 21, 0, 9, 31, 12, 5))
            val code = session.shortCode()
            val typedCode = (code.substring(0, 4) + "-" + code.substring(4)).lowercase()
            for (a in r.jsonObject["attempts"]!!.jsonArray) {
                val attempt = a.jsonObject
                val raw = attempt["token"]!!
                val presented = if (raw is JsonNull) null else when (val t = raw.jsonPrimitive.content) {
                    "\$token" -> session.token()
                    "\$shortCode" -> code
                    "\$shortCodeTyped" -> typedCode
                    else -> t
                }
                val got = session.redeem(presented, attempt["at"]!!.jsonPrimitive.long * 1000, attempt["peer"]!!.jsonPrimitive.content)
                assertEquals(
                    r.jsonObject["name"]!!.jsonPrimitive.content,
                    attempt["expect"]!!.jsonPrimitive.content.lowercase(),
                    got.name.replace("_", "").lowercase(),
                )
            }
            session.close()
        }
    }

    // The private key stays in the Android Keystore: Rust only sees the hash going out and the signature coming back.
    private fun keystoreKey(): Pair<PrivateKey, PublicKey> {
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        generator.initialize(
            KeyGenParameterSpec.Builder("rust-link-test", KeyProperties.PURPOSE_SIGN)
                .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256)
                .build(),
        )
        val pair = generator.generateKeyPair()
        return pair.private to pair.public
    }

    private fun signHash(key: PrivateKey, hash: ByteArray): ByteArray =
        Signature.getInstance("NONEwithECDSA").run {
            initSign(key)
            update(hash)
            sign()
        }

    private fun verifies(key: PublicKey, data: ByteArray, signature: ByteArray): Boolean =
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(key)
            update(data)
            verify(signature)
        }

    @Test
    fun rustHandsTheHashToTheNativeSigner() {
        val (private, public) = keystoreKey()
        val signer = object : Signer {
            override fun sign(hash: ByteArray) = signHash(private, hash)
        }
        val data = byteArrayOf(1, 2, 3, 4, 5)
        assertTrue(verifies(public, data, signData(signer, direct(data))))
    }

    @Test
    fun aNativeSignerThatThrowsComesBackAsAnError() {
        val locked = object : Signer {
            override fun sign(hash: ByteArray): ByteArray = throw IllegalStateException("the key is locked")
        }
        try {
            signData(locked, direct(byteArrayOf(1)))
            fail("expected an error")
        } catch (e: LinkException) {
            assertTrue(e.message, e is LinkException.Unexpected)
        }
    }

    @Test
    fun asyncSigningRoundTrips() = runBlocking {
        val (private, public) = keystoreKey()
        val signer = object : AsyncSigner {
            override suspend fun sign(hash: ByteArray): ByteArray {
                delay(20)
                return signHash(private, hash)
            }
        }
        val data = byteArrayOf(9, 8, 7)
        assertTrue(verifies(public, data, signDataAsync(signer, data)))
    }

    @Test
    fun aRustPanicIsAnException() {
        try {
            panicNow("boom")
            fail("expected an exception")
        } catch (e: InternalException) {
            assertTrue(e.message, e.message!!.contains("boom"))
        }
        // The library keeps working afterwards.
        assertEquals("", checkCode(direct(byteArrayOf(1))))
    }

    @Test
    fun fiftyMegabytesCrossBothWays() {
        val size = 50 * 1024 * 1024
        val data = ByteArray(size) { (it % 251).toByte() }
        val digest = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
        assertEquals(digest, hashBytes(direct(data)))
        assertArrayEquals(data, patternBytes(size.toUInt()))
    }
}
