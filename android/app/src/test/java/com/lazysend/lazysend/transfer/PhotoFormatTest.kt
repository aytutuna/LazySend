package com.lazysend.lazysend.transfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFormatTest {
    @Test
    fun picturesInAnotherFormatAreConverted() {
        for (mime in listOf("image/heic", "image/webp", "image/png", "image/bmp")) assertTrue(mime, converts(PhotoFormat.Jpeg, mime))
        for (mime in listOf("image/heic", "image/webp", "image/jpeg", "image/bmp")) assertTrue(mime, converts(PhotoFormat.Png, mime))
    }

    @Test
    fun aPictureAlreadyInTheFormatIsLeftAlone() {
        assertFalse(converts(PhotoFormat.Jpeg, "image/jpeg"))
        assertFalse(converts(PhotoFormat.Png, "image/png"))
    }

    @Test
    fun originalGifsVideosAndOtherFilesAreNeverConverted() {
        for (mime in listOf("image/jpeg", "image/heic", "video/mp4", "application/pdf", null)) assertFalse(mime, converts(PhotoFormat.Original, mime))
        for (format in listOf(PhotoFormat.Jpeg, PhotoFormat.Png)) {
            for (mime in listOf("image/gif", "image/svg+xml", "video/mp4", "application/pdf", "text/plain", null)) assertFalse("$format $mime", converts(format, mime))
        }
    }

    @Test
    fun theExtensionFollowsTheFormat() {
        assertEquals("IMG_1.jpg", convertedName("IMG_1.heic", PhotoFormat.Jpeg))
        assertEquals("holiday.2026.png", convertedName("holiday.2026.webp", PhotoFormat.Png))
        assertEquals("shot.jpg", convertedName("shot", PhotoFormat.Jpeg))
        assertEquals("IMG_1.heic", convertedName("IMG_1.heic", PhotoFormat.Original))
    }
}
