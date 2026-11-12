package com.lazysend.lazysend.link

/** The ids the PC does not have yet, asked [GALLERY_BATCH] at a time and kept in the order given. */
suspend fun LinkClient.missingIds(ids: List<String>): List<String> =
    ids.chunked(GALLERY_BATCH).flatMap { galleryMissing(it) }
