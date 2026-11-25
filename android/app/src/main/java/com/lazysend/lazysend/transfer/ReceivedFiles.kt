package com.lazysend.lazysend.transfer

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream

const val RECEIVED_FOLDER = "Lazy Send"

interface ReceivedFiles {
    class Part(val uri: String, val size: Long)

    fun existing(uri: String): Part?

    /** [folder] is a path under the Lazy Send folder, such as a guest's name; empty for the folder itself. */
    fun create(name: String, mime: String?, folder: String = ""): Part

    fun append(part: Part): OutputStream

    /** Makes the saved file visible, dated [modified] (epoch milliseconds) when given; returns where it is. */
    fun finish(part: Part, modified: Long? = null): String

    fun discard(uri: String)

    fun read(uri: String): InputStream

    /**
     * Whether [folder] already holds this file, finished, under [name] or "name (2)" and so on, with the same [size] and, when
     * [sha256] is given, the same content. A library file that is already there is noted, not saved twice.
     */
    fun hasCopy(name: String, mime: String?, folder: String, size: Long, sha256: String?): Boolean
}

/** [candidate] is [name], or [name] with " (2)", " (3)"... before its extension, as a saved repeat is called. */
fun isCopyName(candidate: String, name: String): Boolean {
    if (candidate == name) return true
    val dot = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
    return Regex(Regex.escape(name.substring(0, dot)) + " \\(\\d+\\)" + Regex.escape(name.substring(dot))).matches(candidate)
}

/**
 * Where files from the PC are saved: Downloads/Lazy Send, or Pictures/Movies for photos and videos so the
 * gallery shows them. A file being downloaded is kept half-written (pending in the media store, or a
 * .part file before Android 10) so a later attempt can carry on from its size.
 */
class MediaFiles(private val context: Context) : ReceivedFiles {
    override fun existing(uri: String): ReceivedFiles.Part? {
        val size = if (uri.startsWith("file:")) {
            File(Uri.parse(uri).path!!).takeIf { it.exists() }?.length()
        } else {
            runCatching { context.contentResolver.openFileDescriptor(Uri.parse(uri), "r")?.use { it.statSize } }.getOrNull()
        }
        return size?.let { ReceivedFiles.Part(uri, it) }
    }

    override fun create(name: String, mime: String?, folder: String): ReceivedFiles.Part =
        if (Build.VERSION.SDK_INT >= 29) createInMediaStore(name, mime, folder) else createLegacy(name, mime, folder)

    override fun append(part: ReceivedFiles.Part): OutputStream =
        if (part.uri.startsWith("file:")) FileOutputStream(File(Uri.parse(part.uri).path!!), true)
        else context.contentResolver.openOutputStream(Uri.parse(part.uri), "wa")!!

    override fun finish(part: ReceivedFiles.Part, modified: Long?): String {
        if (part.uri.startsWith("file:")) {
            val partial = File(Uri.parse(part.uri).path!!)
            val done = unique(File(partial.parentFile, partial.name.removeSuffix(".part").dropLast(9)))
            partial.renameTo(done)
            if (modified != null) done.setLastModified(modified)
            MediaScannerConnection.scanFile(context, arrayOf(done.path), null, null)
            return Uri.fromFile(done).toString()
        }
        val uri = Uri.parse(part.uri)
        // The media store ignores a DATE_TAKEN an app sets and fills it from the file's own metadata when the file is
        // published, falling back to the file's time. So a file without metadata is dated by setting its time first.
        if (modified != null) {
            @Suppress("DEPRECATION")
            val path = context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
            path?.let { File(it).setLastModified(modified) }
        }
        val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
        if (modified != null) {
            // Android 10 has no file access to set the time with, but may keep these.
            values.put(MediaStore.MediaColumns.DATE_MODIFIED, modified / 1000)
            values.put(MediaStore.MediaColumns.DATE_TAKEN, modified)
        }
        try {
            context.contentResolver.update(uri, values, null, null)
        } catch (e: IllegalArgumentException) {
            context.contentResolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        }
        return part.uri
    }

    override fun discard(uri: String) {
        if (uri.startsWith("file:")) File(Uri.parse(uri).path!!).delete()
        else runCatching { context.contentResolver.delete(Uri.parse(uri), null, null) }
    }

    override fun read(uri: String): InputStream =
        if (uri.startsWith("file:")) File(Uri.parse(uri).path!!).inputStream() else context.contentResolver.openInputStream(Uri.parse(uri))!!

    override fun hasCopy(name: String, mime: String?, folder: String, size: Long, sha256: String?): Boolean {
        val sameContent = { open: () -> InputStream -> sha256 == null || open().use { sha256Of(it) } == sha256 }
        if (Build.VERSION.SDK_INT < 29) {
            val directory = legacyDirectory(mime, folder)
            return directory.listFiles().orEmpty().any { it.isFile && it.length() == size && isCopyName(it.name, name) && sameContent { it.inputStream() } }
        }
        val (collection, base) = mediaStoreFor(mime ?: "application/octet-stream")
        val path = listOf(base, RECEIVED_FOLDER, folder).filter { it.isNotEmpty() }.joinToString("/") + "/"
        val columns = arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME)
        context.contentResolver.query(
            collection, columns, "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND ${MediaStore.MediaColumns.SIZE} = ?", arrayOf(path, size.toString()), null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                if (!isCopyName(cursor.getString(1) ?: continue, name)) continue
                val uri = android.content.ContentUris.withAppendedId(collection, cursor.getLong(0))
                if (sameContent { context.contentResolver.openInputStream(uri) ?: throw java.io.IOException("Cannot open $uri") }) return true
            }
        }
        return false
    }

    private fun sha256Of(input: InputStream): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(128 * 1024)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            digest.update(buffer, 0, n)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun mediaStoreFor(type: String) = when {
        type.startsWith("image/") -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to Environment.DIRECTORY_PICTURES
        type.startsWith("video/") -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to Environment.DIRECTORY_MOVIES
        else -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to Environment.DIRECTORY_DOWNLOADS
    }

    @Suppress("DEPRECATION")
    private fun legacyDirectory(mime: String?, folder: String): File {
        val base = when {
            mime?.startsWith("image/") == true -> Environment.DIRECTORY_PICTURES
            mime?.startsWith("video/") == true -> Environment.DIRECTORY_MOVIES
            else -> Environment.DIRECTORY_DOWNLOADS
        }
        val root = File(Environment.getExternalStoragePublicDirectory(base), RECEIVED_FOLDER)
        return if (folder.isEmpty()) root else File(root, folder)
    }

    private fun createInMediaStore(name: String, mime: String?, folder: String): ReceivedFiles.Part {
        val type = mime ?: "application/octet-stream"
        val (collection, base) = mediaStoreFor(type)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, type)
            put(MediaStore.MediaColumns.RELATIVE_PATH, listOf(base, RECEIVED_FOLDER, folder).filter { it.isNotEmpty() }.joinToString("/"))
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = context.contentResolver.insert(collection, values) ?: error("The media store refused $name")
        // The row has no file behind it until something is written, and existing() reads it before the first chunk.
        try {
            context.contentResolver.openOutputStream(uri, "w")?.close()
        } catch (e: Exception) {
            context.contentResolver.delete(uri, null, null)
            throw e
        }
        return ReceivedFiles.Part(uri.toString(), 0)
    }

    @Suppress("DEPRECATION")
    private fun createLegacy(name: String, mime: String?, folder: String): ReceivedFiles.Part {
        // The same public folders the media store gives on Android 10 and later.
        val directory = legacyDirectory(mime, folder).also { it.mkdirs() }
        val file = File(directory, "$name.${java.util.UUID.randomUUID().toString().take(8)}.part")
        file.delete()
        file.createNewFile()
        return ReceivedFiles.Part(Uri.fromFile(file).toString(), 0)
    }

    private fun unique(file: File): File {
        if (!file.exists()) return file
        val dot = file.name.lastIndexOf('.').takeIf { it > 0 } ?: file.name.length
        var n = 2
        while (true) {
            val candidate = File(file.parentFile, file.name.substring(0, dot) + " ($n)" + file.name.substring(dot))
            if (!candidate.exists()) return candidate
            n++
        }
    }
}
