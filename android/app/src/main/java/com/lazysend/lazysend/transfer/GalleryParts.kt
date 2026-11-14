package com.lazysend.lazysend.transfer

import com.lazysend.lazysend.host.loadJson
import com.lazysend.lazysend.host.saveJson
import java.io.File
import kotlinx.serialization.Serializable

@Serializable
private data class PartsFile(val parts: Map<String, String> = emptyMap())

/**
 * The half-saved gallery file of each item being downloaded, by PC and item id, kept on disk so a part carries on after the
 * process dies instead of starting again and leaving a pending media-store entry behind.
 */
class GalleryParts(private val file: File) {
    private val parts = loadJson(file) { PartsFile() }.parts.toMutableMap()

    @Synchronized
    fun get(key: String): String? = parts[key]

    @Synchronized
    fun put(key: String, uri: String) {
        if (parts.put(key, uri) != uri) file.saveJson(PartsFile(parts))
    }

    @Synchronized
    fun remove(key: String): String? = parts.remove(key)?.also { file.saveJson(PartsFile(parts)) }

    /** Takes out every part of the PC and gives their uris. */
    @Synchronized
    fun removeAll(pcId: String): List<String> {
        val mine = parts.filterKeys { it.startsWith("$pcId/") }
        if (mine.isEmpty()) return emptyList()
        parts.keys.removeAll(mine.keys)
        file.saveJson(PartsFile(parts))
        return mine.values.toList()
    }
}
