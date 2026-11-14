package com.lazysend.lazysend.host

import com.lazysend.lazysend.link.LinkJson
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString

const val MAX_CHUNK_BYTES = 64L * 1024 * 1024
const val MIN_FREE_BYTES = 1024L * 1024 * 1024
const val MAX_SMALL_BODY = 8192L
const val MAX_ITEM_BODY = 8L * 1024 * 1024
const val MAX_GALLERY_BODY = 512L * 1024
const val MAX_TEXT_BYTES = 1024 * 1024
const val MAX_URL_LENGTH = 8192
const val MAX_GALLERY_IDS = 1000
const val MAX_SOURCE_ID = 256
const val MAX_GUESTS = 16
const val MAX_QUEUED = 1000
const val MAX_REPLY_ITEMS = 100
const val MAX_REPLY_INLINE = 4L * 1024 * 1024
const val MAX_NAME_BYTES = 128
const val SERVICE_TYPE = "_lazysend._tcp"

val random = SecureRandom()

/** A phone's, host's or item's id: 8 to 64 letters, digits, '-' and '_', so it is safe as a file name. */
fun isValidId(id: String?): Boolean =
    id != null && id.length in 8..64 && id.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' || it == '_' }

fun newId(): String = UUID.randomUUID().toString().replace("-", "")

fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

fun isValidSourceId(id: String?): Boolean = id != null && id.isNotEmpty() && id.length <= MAX_SOURCE_ID && id.none { Character.isISOControl(it) }

/** A name as kept: control characters removed, trimmed, cut to [maxBytes] UTF-8 bytes. */
fun cleanName(name: String?, maxBytes: Int = MAX_NAME_BYTES): String {
    val text = StringBuilder()
    var bytes = 0
    var i = 0
    val source = name.orEmpty()
    while (i < source.length) {
        val cp = source.codePointAt(i)
        i += Character.charCount(cp)
        if (cp < 0x20 || cp in 0x7F..0x9F) continue
        val size = String(Character.toChars(cp)).toByteArray().size
        if (bytes + size > maxBytes) break
        bytes += size
        text.appendCodePoint(cp)
    }
    return text.toString().trim()
}

fun isAcceptableUrl(url: String?): Boolean {
    if (url == null || url.isEmpty() || url.length > MAX_URL_LENGTH) return false
    val uri = try {
        java.net.URI(url)
    } catch (e: java.net.URISyntaxException) {
        return false
    }
    return (uri.scheme == "http" || uri.scheme == "https") && !uri.host.isNullOrEmpty()
}

/** JSON files are written whole through a temporary file and renamed. */
fun File.writeAtomically(text: String) {
    parentFile?.mkdirs()
    val temp = File(parentFile, "$name.tmp")
    temp.writeText(text)
    if (!temp.renameTo(this)) {
        temp.delete()
        throw IOException("Could not replace $name")
    }
}

/** A file that cannot be read is kept as .bad and replaced by an empty one. */
inline fun <reified T> loadJson(file: File, empty: () -> T): T {
    if (!file.exists()) return empty()
    return try {
        LinkJson.decodeFromString<T>(file.readText())
    } catch (e: Exception) {
        file.renameTo(File(file.parentFile, file.name + ".bad"))
        empty()
    }
}

inline fun <reified T> File.saveJson(value: T) = writeAtomically(LinkJson.encodeToString(value))

/** A file name made safe for any file system: separators and characters some refuse become `_`, cut to 240 UTF-8 bytes keeping the extension. */
fun cleanFileName(name: String?, fallback: String = "file"): String {
    val text = name.orEmpty().map { if (it < ' ' || it in '\u007F'..'\u009F' || it in "/\\:*?\"<>|") '_' else it }.joinToString("").trim(' ', '.')
    if (text.isEmpty()) return fallback
    if (text.toByteArray().size <= MAX_FILE_NAME_BYTES) return text
    val dot = text.lastIndexOf('.')
    val extension = if (dot > 0 && text.length - dot <= 16) text.substring(dot) else ""
    var stem = text.substring(0, text.length - extension.length)
    while (stem.isNotEmpty() && (stem + extension).toByteArray().size > MAX_FILE_NAME_BYTES) stem = stem.dropLast(1)
    return stem.trim(' ', '.').ifEmpty { fallback } + extension
}

const val MAX_FILE_NAME_BYTES = 240
