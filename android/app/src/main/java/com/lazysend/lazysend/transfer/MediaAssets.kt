package com.lazysend.lazysend.transfer

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore

data class Asset(val sourceId: String, val uri: Uri, val name: String, val size: Long, val mime: String, val modifiedMs: Long)

/** The photos and videos this app may read, newest first. With partial access (Android 14) only the ones the user allowed show up. */
open class MediaAssets(private val context: Context) {
    open fun list(): List<Asset> {
        val volumes = if (Build.VERSION.SDK_INT >= 29) MediaStore.getExternalVolumeNames(context) else setOf("external")
        return volumes.flatMap { volume ->
            query(volume, "image", MediaStore.Images.Media.getContentUri(volume)) +
                query(volume, "video", MediaStore.Video.Media.getContentUri(volume))
        }.sortedByDescending { it.modifiedMs }
    }

    private fun query(volume: String, kind: String, collection: Uri): List<Asset> {
        val columns = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.DATE_MODIFIED,
        )
        val found = mutableListOf<Asset>()
        // What came from the PC is saved in a Lazy Send folder and must not go back.
        val (where, args) = if (Build.VERSION.SDK_INT >= 29) {
            "${MediaStore.MediaColumns.RELATIVE_PATH} NOT LIKE ?" to arrayOf("%/${ReceivedFiles.FOLDER}/%")
        } else {
            null to null
        }
        context.contentResolver.query(collection, columns, where, args, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                found += Asset(
                    sourceId = "$volume:$kind:$id",
                    uri = ContentUris.withAppendedId(collection, id),
                    name = cursor.getString(1) ?: "$kind-$id",
                    size = cursor.getLong(2),
                    mime = cursor.getString(3) ?: if (kind == "image") "image/jpeg" else "video/mp4",
                    modifiedMs = cursor.getLong(4) * 1000,
                )
            }
        }
        return found
    }
}
