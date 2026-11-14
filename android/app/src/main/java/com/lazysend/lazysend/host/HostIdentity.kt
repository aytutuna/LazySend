package com.lazysend.lazysend.host

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.ByteArrayInputStream
import java.io.File
import java.net.Socket
import java.security.KeyPair
import java.security.KeyStore
import java.security.KeyPairGenerator
import java.security.Principal
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.net.ssl.KeyManager
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager

/** The key phones pin: a P-256 key that never leaves the Android Keystore, with a self-signed certificate renewed on the same key. */
class HostIdentity(
    private val file: File,
    private val privateKey: PrivateKey,
    publicKey: PublicKey,
    private val name: () -> String,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val spki = publicKey.encoded

    /** SHA-256 of the key's SubjectPublicKeyInfo, which is what the pairing code carries. */
    val fingerprint: ByteArray = sha256(spki)

    /** The certificate to serve: the kept one, or a new one on the same key when there is none or it ends within 60 days. */
    @Synchronized
    fun certificate(): X509Certificate {
        val kept = runCatching {
            CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(file.readBytes())) as X509Certificate
        }.getOrNull()
        val now = clock()
        if (kept != null && kept.publicKey.encoded.contentEquals(spki) && kept.notAfter.time - now > RENEW_BEFORE_MS) return kept
        val fresh = SelfSigned.create("${name()} Lazy Send", spki, privateKey, Date(now - DAY_MS), Date(now + 10 * 365 * DAY_MS))
        file.parentFile?.mkdirs()
        file.writeBytes(fresh.encoded)
        return fresh
    }

    fun sslContext(): SSLContext {
        val chain = arrayOf(certificate())
        return SSLContext.getInstance("TLS").apply { init(arrayOf<KeyManager>(OneKey(privateKey, chain)), null, null) }
    }

    private class OneKey(private val key: PrivateKey, private val chain: Array<X509Certificate>) : X509ExtendedKeyManager() {
        override fun getServerAliases(keyType: String?, issuers: Array<Principal>?) = arrayOf(ALIAS)
        override fun chooseServerAlias(keyType: String?, issuers: Array<Principal>?, socket: Socket?) = ALIAS
        override fun chooseEngineServerAlias(keyType: String?, issuers: Array<Principal>?, engine: SSLEngine?) = ALIAS
        override fun getPrivateKey(alias: String?) = key.takeIf { alias == ALIAS }
        override fun getCertificateChain(alias: String?) = chain.takeIf { alias == ALIAS }
        override fun getClientAliases(keyType: String?, issuers: Array<Principal>?): Array<String>? = null
        override fun chooseClientAlias(keyType: Array<String>?, issuers: Array<Principal>?, socket: Socket?): String? = null
    }

    companion object {
        private const val ALIAS = "lazysend-host"
        private const val DAY_MS = 24 * 60 * 60 * 1000L
        private const val RENEW_BEFORE_MS = 60 * DAY_MS

        /** The Keystore key, made on first use. */
        fun androidKey(): KeyPair {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            if (!store.containsAlias(ALIAS)) {
                val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
                    .build()
                KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply { initialize(spec) }.generateKeyPair()
            }
            return KeyPair(store.getCertificate(ALIAS).publicKey, store.getKey(ALIAS, null) as PrivateKey)
        }
    }
}

/** An X.509 v3 certificate built by hand, so it can be signed by a key that cannot be exported. */
object SelfSigned {
    fun create(commonName: String, spki: ByteArray, signer: PrivateKey, from: Date, to: Date): X509Certificate {
        val serial = ByteArray(8).also { random.nextBytes(it) }.also { it[0] = (it[0].toInt() and 0x3F or 0x01).toByte() }
        val sigAlgorithm = der(0x30, der(0x06, byteArrayOf(0x2A, 0x86.toByte(), 0x48, 0xCE.toByte(), 0x3D, 0x04, 0x03, 0x02)))
        val name = der(0x30, der(0x31, der(0x30, der(0x06, byteArrayOf(0x55, 0x04, 0x03)), der(0x0C, commonName.toByteArray()))))
        val keyUsage = der(0x30, der(0x06, byteArrayOf(0x55, 0x1D, 0x0F)), der(0x01, byteArrayOf(0xFF.toByte())), der(0x04, der(0x03, byteArrayOf(0x07, 0x80.toByte()))))
        val serverAuth = byteArrayOf(0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01)
        val extendedKeyUsage = der(0x30, der(0x06, byteArrayOf(0x55, 0x1D, 0x25)), der(0x04, der(0x30, der(0x06, serverAuth))))
        val tbs = der(
            0x30,
            der(0xA0, der(0x02, byteArrayOf(2))),
            der(0x02, serial),
            sigAlgorithm,
            name,
            der(0x30, utcTime(from), utcTime(to)),
            name,
            spki,
            der(0xA3, der(0x30, keyUsage, extendedKeyUsage)),
        )
        val signature = Signature.getInstance("SHA256withECDSA").run {
            initSign(signer)
            update(tbs)
            sign()
        }
        val certificate = der(0x30, tbs, sigAlgorithm, der(0x03, byteArrayOf(0) + signature))
        return CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(certificate)) as X509Certificate
    }

    private fun utcTime(date: Date): ByteArray {
        val format = SimpleDateFormat("yyMMddHHmmss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        return der(0x17, format.format(date).toByteArray())
    }

    private fun der(tag: Int, vararg parts: ByteArray): ByteArray {
        val body = parts.fold(ByteArray(0)) { all, part -> all + part }
        val length = when {
            body.size < 0x80 -> byteArrayOf(body.size.toByte())
            body.size < 0x100 -> byteArrayOf(0x81.toByte(), body.size.toByte())
            else -> byteArrayOf(0x82.toByte(), (body.size shr 8).toByte(), body.size.toByte())
        }
        return byteArrayOf(tag.toByte()) + length + body
    }
}
