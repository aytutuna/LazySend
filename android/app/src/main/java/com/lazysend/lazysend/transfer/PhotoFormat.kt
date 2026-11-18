package com.lazysend.lazysend.transfer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import java.io.File
import java.util.UUID

/** What photos are sent as: converted to JPEG or PNG, or left as they are. */
enum class PhotoFormat(val mime: String?, val extension: String?) {
    Jpeg("image/jpeg", "jpg"),
    Original(null, null),
    Png("image/png", "png"),
}

/** Pictures in a format of their own are converted; a GIF would lose its frames, a vector picture cannot be decoded, and video is not a picture. */
fun converts(format: PhotoFormat, mime: String?): Boolean =
    format.mime != null && mime != null && mime.startsWith("image/") && mime != format.mime && mime != "image/gif" && mime != "image/svg+xml"

/** The name with the extension of [format]; a name without one gets it added. */
fun convertedName(name: String, format: PhotoFormat): String {
    val extension = format.extension ?: return name
    val dot = name.lastIndexOf('.')
    return (if (dot > 0) name.substring(0, dot) else name) + "." + extension
}

private const val JPEG_QUALITY = 92

/** Writes [source] as [format] into a folder of its own under [parent], upright, and returns it; null when the picture cannot be read. */
fun convertPhoto(context: Context, source: Uri, name: String, format: PhotoFormat, parent: File): File? = try {
    val bitmap = decode(context, source)?.let { flatten(it, format) } ?: return null
    val out = File(File(parent, UUID.randomUUID().toString()).also { it.mkdirs() }, convertedName(name, format))
    out.outputStream().use {
        bitmap.compress(if (format == PhotoFormat.Png) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, JPEG_QUALITY, it)
    }
    out
} catch (e: Exception) {
    null
}

// A JPEG has no transparency, so a picture that has some is put on white.
private fun flatten(bitmap: Bitmap, format: PhotoFormat): Bitmap {
    if (format == PhotoFormat.Png || !bitmap.hasAlpha()) return bitmap
    val flat = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
    Canvas(flat).apply {
        drawColor(android.graphics.Color.WHITE)
        drawBitmap(bitmap, 0f, 0f, null)
    }
    return flat
}

// The orientation is applied to the pixels, since neither a PNG nor a re-encoded file should depend on a tag.
private fun decode(context: Context, uri: Uri): Bitmap? {
    if (Build.VERSION.SDK_INT >= 28) {
        return ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, _, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
    }
    val bitmap = context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) } ?: return null
    val orientation = context.contentResolver.openInputStream(uri)?.use {
        ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
    } ?: ExifInterface.ORIENTATION_NORMAL
    val matrix = Matrix()
    when (orientation) {
        ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
        ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
        ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
        ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
        ExifInterface.ORIENTATION_TRANSPOSE -> matrix.apply { postRotate(90f); postScale(-1f, 1f) }
        ExifInterface.ORIENTATION_TRANSVERSE -> matrix.apply { postRotate(270f); postScale(-1f, 1f) }
        else -> return bitmap
    }
    return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
}
