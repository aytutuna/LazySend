package com.lazysend.lazysend.scan

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import kotlin.math.max

/** JPEG bytes for a page. */
object JpegEncoder {
    const val QUALITY = 85

    /**
     * `image` as a JPEG, or null when the platform cannot make it. The platform encoder always writes three components,
     * so a gray page is encoded from its luma with equal channels, which costs no chroma.
     */
    fun encode(image: RgbaImage, gray: Boolean): ByteArray? {
        val count = image.width * image.height
        val colors = IntArray(count)
        if (gray) {
            val luma = GrayImage.luma(image).pixels
            for (i in 0 until count) {
                val v = luma[i].toInt() and 0xFF
                colors[i] = (0xFF shl 24) or (v shl 16) or (v shl 8) or v
            }
        } else {
            val p = image.pixels
            for (i in 0 until count) {
                colors[i] = (0xFF shl 24) or ((p[i * 4].toInt() and 0xFF) shl 16) or
                    ((p[i * 4 + 1].toInt() and 0xFF) shl 8) or (p[i * 4 + 2].toInt() and 0xFF)
            }
        }
        val bitmap = Bitmap.createBitmap(colors, image.width, image.height, Bitmap.Config.ARGB_8888)
        try {
            val out = ByteArrayOutputStream()
            return if (bitmap.compress(Bitmap.CompressFormat.JPEG, QUALITY, out)) out.toByteArray() else null
        } finally {
            bitmap.recycle()
        }
    }
}

/** A photo read for scanning, with its orientation tag applied. */
object PhotoReader {
    /** The long side a photo is read at, at most: a camera shot is 12 megapixels, so this is about whole. */
    const val MAX_LONG_SIDE = 4096

    fun decode(bytes: ByteArray): RgbaImage? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val options = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            // A little under the limit, so a 8160 px sensor is read at half size instead of whole (200 MB) and then shrunk.
            inSampleSize = sampleSize(max(bounds.outWidth, bounds.outHeight), MAX_LONG_SIDE * 19 / 20)
        }
        var bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
        val big = max(bitmap.width, bitmap.height)
        if (big > MAX_LONG_SIDE) {
            val scale = MAX_LONG_SIDE.toDouble() / big
            val scaled = Bitmap.createScaledBitmap(bitmap, max(1, (bitmap.width * scale).toInt()),
                max(1, (bitmap.height * scale).toInt()), true)
            if (scaled !== bitmap) bitmap.recycle()
            bitmap = scaled
        }
        orientation(bytes)?.let { matrix ->
            val turned = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            if (turned !== bitmap) bitmap.recycle()
            bitmap = turned
        }
        val w = bitmap.width
        val h = bitmap.height
        val colors = IntArray(w * h)
        bitmap.getPixels(colors, 0, w, 0, 0, w, h)
        bitmap.recycle()
        val pixels = ByteArray(w * h * 4)
        for (i in colors.indices) {
            val c = colors[i]
            pixels[i * 4] = (c shr 16).toByte()
            pixels[i * 4 + 1] = (c shr 8).toByte()
            pixels[i * 4 + 2] = c.toByte()
            pixels[i * 4 + 3] = -1
        }
        return RgbaImage(w, h, pixels)
    }

    private fun orientation(bytes: ByteArray): Matrix? {
        val tag = try {
            ExifInterface(ByteArrayInputStream(bytes))
                .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (e: IOException) {
            return null
        }
        val m = Matrix()
        when (tag) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> { m.setRotate(180f); m.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSPOSE -> { m.setRotate(90f); m.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_90 -> m.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> { m.setRotate(-90f); m.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_270 -> m.setRotate(-90f)
            else -> return null
        }
        return m
    }
}

/** The largest power of two that still leaves the long side at `target` or more. */
private fun sampleSize(longSide: Int, target: Int): Int {
    var sample = 1
    while (longSide / (sample * 2) >= target) sample *= 2
    return sample
}

/** The JPEG decoded no larger than about `maxSide` on its long side; null when it is not a picture. */
fun ByteArray.toThumbnail(maxSide: Int): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(this, 0, size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    val options = BitmapFactory.Options().apply {
        inSampleSize = sampleSize(max(bounds.outWidth, bounds.outHeight), maxSide)
    }
    return BitmapFactory.decodeByteArray(this, 0, size, options)
}
