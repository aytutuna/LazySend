package com.lazysend.lazysend.host

import com.lazysend.lazysend.link.decodeBase64Url
import com.lazysend.lazysend.link.encodeBase64Url
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

/** A phone or computer paired with this phone as its host. Only the SHA-256 of its secret is kept. */
@Serializable
data class Guest(
    val id: String,
    val name: String,
    val platform: String,
    val appVersion: String,
    val secretHash: String,
    val paired: Long,
    val lastSeen: Long,
)

@Serializable
private data class GuestFile(val guests: List<Guest> = emptyList())

class TooManyGuests : Exception("Too many guests are paired.")

/** The guests of this phone, in a JSON file. Safe to use from any thread. */
class GuestStore(private val file: File) {
    private val state = MutableStateFlow(loadJson(file) { GuestFile() }.guests)

    val guests: StateFlow<List<Guest>> get() = state

    fun get(id: String): Guest? = state.value.firstOrNull { it.id == id }

    /**
     * Pairs the guest [id] (pairing again replaces its entry and secret) and returns its new secret, base64url of 32
     * bytes, to be sent once. Throws [TooManyGuests], and [IOException] when the pairing cannot be saved: a guest must not
     * believe it is paired when it is not.
     */
    @Synchronized
    fun pair(id: String, name: String, platform: String, appVersion: String, now: Long): String {
        require(isValidId(id)) { "The guest's id is not valid." }
        val secret = ByteArray(32).also { random.nextBytes(it) }
        val before = state.value
        val others = before.filter { it.id != id }
        if (others.size >= MAX_GUESTS) throw TooManyGuests()
        state.value = others + Guest(id, name, platform, appVersion, hex(sha256(secret)), now, now)
        try {
            save()
        } catch (e: IOException) {
            state.value = before
            throw e
        }
        return encodeBase64Url(secret)
    }

    /** The guest [id] when [secret] is its secret (compared in constant time). */
    @Synchronized
    fun authenticate(id: String?, secret: String?, now: Long): Guest? {
        if (!isValidId(id)) return null
        val bytes = secret?.let(::decodeBase64Url)?.takeIf { it.size == 32 } ?: return null
        val guest = state.value.firstOrNull { it.id == id } ?: return null
        if (guest.secretHash.length != 64) return null
        val stored = guest.secretHash.chunked(2).map { it.toIntOrNull(16)?.toByte() ?: return null }.toByteArray()
        if (!MessageDigest.isEqual(sha256(bytes), stored)) return null
        if (now - guest.lastSeen >= LAST_SEEN_RESOLUTION_MS || now < guest.lastSeen) {
            val seen = guest.copy(lastSeen = now)
            state.value = state.value.map { if (it.id == id) seen else it }
            // Only the last-seen time is lost when this cannot be written.
            runCatching { save() }
            return seen
        }
        return guest
    }

    @Synchronized
    fun remove(id: String): Boolean {
        if (state.value.none { it.id == id }) return false
        state.value = state.value.filterNot { it.id == id }
        save()
        return true
    }

    @Synchronized
    fun clear() {
        state.value = emptyList()
        save()
    }

    private fun save() = file.saveJson(GuestFile(state.value))

    companion object {
        const val LAST_SEEN_RESOLUTION_MS = 60_000L
    }
}
