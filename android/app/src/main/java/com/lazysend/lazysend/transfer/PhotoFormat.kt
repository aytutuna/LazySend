package com.lazysend.lazysend.transfer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import android.os.Build
import java.io.File
import java.util.UUID

/** What photos are sent as: converted to JPEG or PNG, or left as they are. */
enum class PhotoFormat(val mime: String?, val extension: String?) {
    Jpeg("image/jpeg", "jpg"),
    Original(null, null),
    Png("image/png", "png"),
}

/**
 * JPEG is for phone photos in HEIC, HEIF or WebP; a PNG, which may be a screenshot, stays lossless and nothing with transparency is
 * flattened. PNG converts any still picture. Left as they are under both: a GIF or an animated picture (which would lose its
 * frames), a vector picture, AVIF, and camera raw files (image/x-...).
 */
fun converts(format: PhotoFormat, mime: String?): Boolean = mime != null && when (format) {
    PhotoFormat.Original -> false
    PhotoFormat.Jpeg -> mime in JPEG_SOURCES
    PhotoFormat.Png -> mime.startsWith("image/") && mime != "image/png" && mime !in KEPT && !(mime.startsWith("image/x-") && mime != "image/x-ms-bmp")
}

private val JPEG_SOURCES = setOf("image/heic", "image/heif", "image/webp")

private val KEPT = setOf("image/gif", "image/svg+xml", "image/avif", "image/avif-sequence", "image/apng")

/** The name with the extension of [format]; a name without one gets it added. */
fun convertedName(name: String, format: PhotoFormat): String {
    val extension = format.extension ?: return name
    val dot = name.lastIndexOf('.')
    return (if (dot > 0) name.substring(0, dot) else name) + "." + extension
}

/** Whether the start of a WebP or PNG file says it has frames, which a conversion would cut down to one. */
fun isAnimated(mime: String?, head: ByteArray): Boolean = when (mime) {
    "image/webp" -> head.size > 20 && String(head, 0, 4, Charsets.ISO_8859_1) == "RIFF" &&
        String(head, 8, 8, Charsets.ISO_8859_1) == "WEBPVP8X" && head[20].toInt() and 2 != 0
    "image/png" -> String(head, Charsets.ISO_8859_1).let { text ->
        val control = text.indexOf("acTL")
        val data = text.indexOf("IDAT")
        control >= 0 && (data < 0 || control < data)
    }
    else -> false
}

/** Whether the start of a WebP file says it has transparency (the alpha flag of its extended header, or of a lossless one). */
fun hasAlpha(mime: String?, head: ByteArray): Boolean {
    if (mime != "image/webp" || head.size < 25 || String(head, 0, 4, Charsets.ISO_8859_1) != "RIFF" || String(head, 8, 4, Charsets.ISO_8859_1) != "WEBP") return false
    return when (String(head, 12, 4, Charsets.ISO_8859_1)) {
        "VP8X" -> head[20].toInt() and 0x10 != 0
        "VP8L" -> head[24].toInt() and 0x10 != 0
        else -> false
    }
}

private const val JPEG_QUALITY = 92
private const val MAX_PIXELS = 40_000_000L

/** How much to shrink a picture so a decode stays at about 40 megapixels or less. */
fun sampleSizeFor(width: Int, height: Int): Int {
    var sample = 1
    while ((width.toLong() / sample) * (height.toLong() / sample) > MAX_PIXELS) sample++
    return sample
}

/** The folder converted pictures wait in until sent; what is a day old goes. */
fun convertedFolder(context: Context): File {
    val dir = File(context.cacheDir, "converted").apply { mkdirs() }
    dir.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 24 * 60 * 60 * 1000L }?.forEach { it.deleteRecursively() }
    return dir
}

/** The picture in the chosen format as an address to send, or [uri] itself when it is not converted or cannot be. */
fun preparedForSend(context: Context, uri: Uri, format: PhotoFormat): Uri {
    val mime = runCatching { context.contentResolver.getType(uri) }.getOrNull()
    if (!converts(format, mime)) return uri
    val name = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null }
    }.getOrNull()
    val file = convertPhoto(context, uri, name ?: uri.lastPathSegment ?: "photo", mime, format, convertedFolder(context)) ?: return uri
    return FileProvider.getUriForFile(context, "${context.packageName}.files", file)
}

/**
 * Writes [source] as [format] into a folder of its own under [parent], upright, and returns it. Null when the picture cannot be
 * converted, for any reason a huge or odd picture can fail (memory included), so the caller sends the original.
 */
fun convertPhoto(context: Context, source: Uri, name: String, mime: String?, format: PhotoFormat, parent: File): File? {
    var folder: File? = null
    return try {
        val head = context.contentResolver.openInputStream(source)?.use { it.readNBytes(64 * 1024) } ?: return null
        if (isAnimated(mime, head) || (format == PhotoFormat.Jpeg && hasAlpha(mime, head))) return null
        val bitmap = decode(context, source) ?: return null
        folder = File(parent, UUID.randomUUID().toString()).also { it.mkdirs() }
        val out = File(folder, convertedName(name, format))
        out.outputStream().use {
            bitmap.compress(if (format == PhotoFormat.Png) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, JPEG_QUALITY, it)
        }
        if (format == PhotoFormat.Jpeg) copyExif(context, source, out)
        out
    } catch (e: Throwable) {
        folder?.deleteRecursively()
        null
    }
}

// The date, camera, lens and place travel with a JPEG; the picture itself is upright now, so its orientation is normal.
private val KEPT_TAGS = listOf(
    ExifInterface.TAG_DATETIME, ExifInterface.TAG_DATETIME_ORIGINAL, ExifInterface.TAG_DATETIME_DIGITIZED,
    ExifInterface.TAG_SUBSEC_TIME, ExifInterface.TAG_SUBSEC_TIME_ORIGINAL, ExifInterface.TAG_SUBSEC_TIME_DIGITIZED,
    "OffsetTime", "OffsetTimeOriginal", "OffsetTimeDigitized",
    ExifInterface.TAG_MAKE, ExifInterface.TAG_MODEL, "LensMake", "LensModel",
    ExifInterface.TAG_GPS_LATITUDE, ExifInterface.TAG_GPS_LATITUDE_REF, ExifInterface.TAG_GPS_LONGITUDE, ExifInterface.TAG_GPS_LONGITUDE_REF,
    ExifInterface.TAG_GPS_ALTITUDE, ExifInterface.TAG_GPS_ALTITUDE_REF, ExifInterface.TAG_GPS_TIMESTAMP, ExifInterface.TAG_GPS_DATESTAMP,
    ExifInterface.TAG_GPS_PROCESSING_METHOD,
)

private fun copyExif(context: Context, source: Uri, target: File) {
    try {
        val from = context.contentResolver.openInputStream(source)?.use { ExifInterface(it) } ?: return
        val to = ExifInterface(target.path)
        for (tag in KEPT_TAGS) from.getAttribute(tag)?.let { to.setAttribute(tag, it) }
        to.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
        to.saveAttributes()
    } catch (e: Exception) {
        // The picture is fine without them.
    }
}

// The orientation is applied to the pixels, since neither a PNG nor a re-encoded file should depend on a tag.
private fun decode(context: Context, uri: Uri): Bitmap? {
    if (Build.VERSION.SDK_INT >= 28) {
        return ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.setTargetSampleSize(sampleSizeFor(info.size.width, info.size.height))
        }
    }
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
    val options = BitmapFactory.Options().apply { inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight) }
    val bitmap = context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) } ?: return null
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
