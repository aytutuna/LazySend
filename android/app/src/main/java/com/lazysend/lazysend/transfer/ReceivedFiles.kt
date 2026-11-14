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
        if (Build.VERSION.SDK_INT >= 29) createInMediaStore(name, mime, folder) else createLegacy(name, folder)

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
        val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
        if (modified != null) {
            values.put(MediaStore.MediaColumns.DATE_MODIFIED, modified / 1000)
            values.put(MediaStore.MediaColumns.DATE_TAKEN, modified)
        }
        try {
            context.contentResolver.update(uri, values, null, null)
        } catch (e: IllegalArgumentException) {
            // A collection without those date columns: the file is still put in place, only undated.
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

    private fun createInMediaStore(name: String, mime: String?, folder: String): ReceivedFiles.Part {
        val type = mime ?: "application/octet-stream"
        val (collection, base) = when {
            type.startsWith("image/") -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to Environment.DIRECTORY_PICTURES
            type.startsWith("video/") -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to Environment.DIRECTORY_MOVIES
            else -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to Environment.DIRECTORY_DOWNLOADS
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, type)
            put(MediaStore.MediaColumns.RELATIVE_PATH, listOf(base, RECEIVED_FOLDER, folder).filter { it.isNotEmpty() }.joinToString("/"))
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = context.contentResolver.insert(collection, values) ?: error("The media store refused $name")
        return ReceivedFiles.Part(uri.toString(), 0)
    }

    @Suppress("DEPRECATION")
    private fun createLegacy(name: String, folder: String): ReceivedFiles.Part {
        val root = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), RECEIVED_FOLDER)
        val directory = (if (folder.isEmpty()) root else File(root, folder)).also { it.mkdirs() }
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
