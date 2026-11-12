package com.lazysend.lazysend.link

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

val LinkJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
}

const val PROTOCOL_VERSION = 1
const val DEFAULT_PORT = 52734
const val CHUNK_BYTES = 8L * 1024 * 1024
const val GALLERY_BATCH = 1000
const val MAX_OUTBOX_WAIT = 25

@Serializable
data class PairRequest(
    val token: String,
    val phoneId: String,
    val phoneName: String,
    val platform: String = "android",
    val appVersion: String,
)

@Serializable
data class PairResponse(val protocolVersion: Int, val desktopId: String, val desktopName: String, val deviceSecret: String)

@Serializable
data class Health(val service: String, val protocolVersion: Int, val paired: Boolean = false)

@Serializable
data class Hello(
    val protocolVersion: Int,
    val desktopId: String,
    val desktopName: String,
    val maxChunkBytes: Long = 64L * 1024 * 1024,
    val addresses: List<String> = emptyList(),
)

@Serializable
data class ItemRequest(
    val kind: String,
    val text: String? = null,
    val url: String? = null,
    val name: String? = null,
    val size: Long? = null,
    val mime: String? = null,
    val modified: String? = null,
    val sourceId: String? = null,
    val sha256: String? = null,
)

@Serializable
data class ItemState(val id: String, val offset: Long, val done: Boolean, val duplicate: Boolean? = null)

@Serializable
data class GalleryCheckRequest(val ids: List<String>)

@Serializable
data class GalleryCheckReply(val missing: List<String>)

@Serializable
data class OutboxEntry(
    val id: String,
    val kind: String,
    val text: String? = null,
    val url: String? = null,
    val name: String? = null,
    val size: Long? = null,
    val mime: String? = null,
)

@Serializable
data class OutboxReply(val items: List<OutboxEntry> = emptyList(), val more: Boolean? = null)

@Serializable
data class ApiError(val error: String, val message: String = "", val offset: Long? = null)

/** An error answer from the PC: [code] is one of the stable codes in CONTRACTS.md. */
class LinkException(val status: Int, val code: String, message: String, val offset: Long? = null) : Exception(message)
