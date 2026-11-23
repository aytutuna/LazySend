package com.lazysend.lazysend.transfer

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.widget.Toast
import androidx.core.content.FileProvider
import com.lazysend.lazysend.R
import com.lazysend.lazysend.data.EntryKind
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What an item that arrived with the clip flag puts on the clipboard. */
sealed interface ClipContent {
    data class Text(val text: String) : ClipContent

    data class Link(val url: String) : ClipContent

    /** A saved file, by the address it was saved at. */
    data class Saved(val uri: String, val mime: String?, val name: String) : ClipContent
}

/** Null when there is nothing to put on the clipboard: no text, or a file that is not saved. */
fun clipContent(kind: EntryKind, title: String, uri: String?, mime: String?): ClipContent? = when (kind) {
    EntryKind.Text -> title.takeIf { it.isNotEmpty() }?.let { ClipContent.Text(it) }
    EntryKind.Link -> title.takeIf { it.isNotEmpty() }?.let { ClipContent.Link(it) }
    EntryKind.File -> uri?.let { ClipContent.Saved(it, mime, title) }
    EntryKind.Gallery -> null
}

/** What the clipboard holds that can be sent. */
sealed interface Pasted {
    data class Note(val text: String) : Pasted

    data class Attachment(val uri: String, val mime: String) : Pasted
}

/** A content address of a picture or other file wins over text; a note must have something in it. */
fun pasted(text: CharSequence?, uri: String?, mime: String?): Pasted? = when {
    uri != null && mime != null && !mime.startsWith("text/") -> Pasted.Attachment(uri, mime)
    !text.isNullOrBlank() -> Pasted.Note(text.toString())
    else -> null
}

private val STAMP = DateTimeFormatter.ofPattern("yyyy-MM-dd HH.mm.ss", Locale.ROOT)
private val STAMP_MS = DateTimeFormatter.ofPattern("yyyy-MM-dd HH.mm.ss.SSS", Locale.ROOT)
private val STAMP_MINUTE = DateTimeFormatter.ofPattern("yyyy-MM-dd HH.mm", Locale.ROOT)

/** The name of a camera photo; the milliseconds are added only when [taken] says the plain name is in use. */
fun photoName(time: Long, zone: ZoneId = ZoneId.systemDefault(), taken: (String) -> Boolean = { false }): String {
    val moment = Instant.ofEpochMilli(time).atZone(zone)
    val plain = "Photo ${STAMP.format(moment)}.jpg"
    return if (taken(plain)) "Photo ${STAMP_MS.format(moment)}.jpg" else plain
}

/** The name of a scan, to the minute; the seconds and milliseconds are added only when [taken] says the plain name is in use. */
fun scanName(time: Long, extension: String, zone: ZoneId = ZoneId.systemDefault(), taken: (String) -> Boolean = { false }): String {
    val moment = Instant.ofEpochMilli(time).atZone(zone)
    val plain = "Scan ${STAMP_MINUTE.format(moment)}.$extension"
    return if (taken(plain)) "Scan ${STAMP_MS.format(moment)}.$extension" else plain
}

fun clipboardName(time: Long, extension: String, zone: ZoneId = ZoneId.systemDefault()): String =
    "Clipboard ${STAMP.format(Instant.ofEpochMilli(time).atZone(zone))}.$extension"

/** Other apps are refused a file:// address, so files saved before Android 10 are handed over through a provider. */
fun shareableUri(context: Context, uri: Uri): Uri =
    if (uri.scheme == "file") FileProvider.getUriForFile(context, "${context.packageName}.files", File(uri.path!!)) else uri

/** Puts received items on this phone's clipboard. */
class Clipper(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun put(content: ClipContent, from: String) {
        scope.launch {
            val data = try {
                when (content) {
                    is ClipContent.Text -> ClipData.newPlainText(null, content.text)
                    is ClipContent.Link -> ClipData.newPlainText(null, content.url)
                    is ClipContent.Saved -> ClipData.newUri(context.contentResolver, content.name, shareableUri(context, Uri.parse(content.uri)))
                }
            } catch (e: Exception) {
                return@launch
            }
            withContext(Dispatchers.Main) {
                context.getSystemService(ClipboardManager::class.java).setPrimaryClip(data)
                // Android 13 and later shows its own confirmation.
                if (Build.VERSION.SDK_INT < 33) Toast.makeText(context, context.getString(R.string.copied_from, from), Toast.LENGTH_SHORT).show()
            }
        }
    }
}
