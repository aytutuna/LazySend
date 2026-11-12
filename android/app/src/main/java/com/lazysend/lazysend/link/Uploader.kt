package com.lazysend.lazysend.link

import java.io.IOException
import java.security.MessageDigest
import kotlinx.coroutines.delay

data class UploadResult(val duplicate: Boolean)

/**
 * Sends one file in chunks and carries on after drops: it asks the PC where the file stands
 * and continues from the offset it is told, never from what it sent. One instance per file.
 */
class Uploader(
    private val connect: suspend () -> LinkClient,
    private val chunkBytes: Long = CHUNK_BYTES,
    private val retryDelaysMs: List<Long> = listOf(1000, 2000, 4000, 8000, 15000, 30000, 30000, 30000),
) {
    private lateinit var client: LinkClient

    /** [onProgress] gets the bytes the PC is known to have. Throws [IOException] once the PC has stayed out of reach. */
    suspend fun sendFile(request: ItemRequest, source: DataSource, onProgress: (Long) -> Unit = {}): UploadResult {
        val size = request.size ?: error("A file needs a size")
        client = connect()
        var restarted = false
        var state = begin(request)
        if (state.duplicate == true) return UploadResult(duplicate = true)
        onProgress(state.offset)
        while (!state.done) {
            state = try {
                sendChunk(state, minOf(chunkBytes, size - state.offset), source)
            } catch (e: LinkException) {
                when {
                    e.code == "offsetMismatch" && e.offset != null -> ItemState(state.id, e.offset, false)
                    (e.code == "hashMismatch" || e.code == "notFound") && !restarted -> {
                        restarted = true
                        begin(request)
                    }
                    else -> throw e
                }
            }
            onProgress(state.offset)
        }
        return UploadResult(duplicate = false)
    }

    private suspend fun begin(request: ItemRequest): ItemState {
        var failures = 0
        while (true) {
            try {
                return client.postItem(request)
            } catch (e: IOException) {
                failures = backOff(failures, e)
            }
        }
    }

    private suspend fun sendChunk(state: ItemState, length: Long, source: DataSource): ItemState {
        var failures = 0
        while (true) {
            try {
                return client.putChunk(state.id, state.offset, length, source)
            } catch (e: IOException) {
                failures = backOff(failures, e)
                // The chunk may have landed before the answer was lost, so ask before sending it again.
                try {
                    return client.itemState(state.id)
                } catch (_: IOException) {
                }
            }
        }
    }

    private suspend fun backOff(failures: Int, cause: IOException): Int {
        if (failures >= retryDelaysMs.size) throw cause
        delay(retryDelaysMs[failures])
        client = try {
            connect()
        } catch (_: IOException) {
            client
        }
        return failures + 1
    }
}

fun sha256Hex(source: DataSource): String {
    val digest = MessageDigest.getInstance("SHA-256")
    source.open(0).use { input ->
        val buffer = ByteArray(128 * 1024)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            digest.update(buffer, 0, n)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}
