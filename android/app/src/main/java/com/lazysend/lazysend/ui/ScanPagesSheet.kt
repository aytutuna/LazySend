package com.lazysend.lazysend.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.lazysend.lazysend.R
import com.lazysend.lazysend.scan.ScanModel
import com.lazysend.lazysend.scan.ScanPage
import kotlinx.coroutines.launch

/**
 * The pages taken so far, in the order they will go: look at one, cut it again, move it earlier or later, delete it. Done sends
 * them to the chosen device, one page as the image it is and more as one PDF. It stays up while pages are sent or cut.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScanPagesSheet(scan: ScanModel, target: String?, onClose: () -> Unit) {
    val closable by rememberUpdatedState(scan.canCrop.collectAsState().value)
    val pages by scan.pages.collectAsState()
    val sending by scan.sending.collectAsState()
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true, confirmValueChange = { it != SheetValue.Hidden || closable })
    val scope = rememberCoroutineScope()
    fun close() = scope.launch {
        state.hide()
        onClose()
    }
    LaunchedEffect(pages.isEmpty(), sending) { if (pages.isEmpty() && !sending) close() }
    ModalBottomSheet(onDismissRequest = { if (closable) onClose() }, sheetState = state) {
        ScanPagesContent(scan, target, onKeep = { close() })
    }
}

@Composable
fun ScanPagesContent(scan: ScanModel, target: String?, onKeep: () -> Unit) {
    val pages by scan.pages.collectAsState()
    val sending by scan.sending.collectAsState()
    val working by scan.working.collectAsState()
    val canCrop by scan.canCrop.collectAsState()
    val busy by scan.busy.collectAsState()
    val problem by scan.problem.collectAsState()
    val sendingLabel = stringResource(R.string.sending)
    var viewing by remember { mutableStateOf<ScanPage?>(null) }

    Column(Modifier.fillMaxWidth().navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onKeep, enabled = canCrop) { Text(stringResource(R.string.scan_keep)) }
            Text(pagesText(pages.size), Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
            if (sending) CircularProgressIndicator(Modifier.size(20.dp).semantics { contentDescription = sendingLabel }, strokeWidth = 2.dp)
            Button(onClick = { scan.done() }, enabled = pages.isNotEmpty() && target != null && !sending && !working) { Text(stringResource(R.string.done)) }
        }
        if (pages.isEmpty()) {
            Text(stringResource(R.string.scan_no_pages), Modifier.fillMaxWidth().padding(32.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
        LazyColumn(Modifier.weight(1f, fill = false)) {
            itemsIndexed(pages, key = { _, page -> page.id }) { index, page ->
                PageRow(scan, index, pages.size, page, canCrop, busy) { viewing = page }
            }
            if (target != null && pages.isNotEmpty()) {
                item {
                    Text(
                        stringResource(if (pages.size == 1) R.string.scan_done_image else R.string.scan_done_pdf, target),
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
        problem?.let {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { ProblemPill(problemText(it)) }
        }
    }
    viewing?.let { PageViewer(it) { viewing = null } }
}

@Composable
private fun PageRow(scan: ScanModel, index: Int, count: Int, page: ScanPage, canCrop: Boolean, busy: Boolean, onView: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val thumb = remember(page.id, page.jpeg) { scan.thumbnail(page) }
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.weight(1f).clickable(onClick = onView), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.size(width = 48.dp, height = 64.dp).clip(RoundedCornerShape(4.dp)).background(MaterialTheme.colorScheme.surfaceVariant)) {
                thumb?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
            }
            Column {
                Text(stringResource(R.string.scan_page, index + 1))
                Text(stringResource(filterName(page.filter)), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            }
        }
        Box {
            IconButton({ menu = true }) { Icon(painterResource(R.drawable.ic_more), stringResource(R.string.scan_page_options, index + 1)) }
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem(text = { Text(stringResource(R.string.scan_view)) }, onClick = { menu = false; onView() })
                DropdownMenuItem(text = { Text(stringResource(R.string.scan_crop)) }, enabled = canCrop, onClick = { menu = false; scan.recut(page) })
                DropdownMenuItem(text = { Text(stringResource(R.string.scan_move_earlier)) }, enabled = index > 0, onClick = { menu = false; scan.shift(page.id, -1) })
                DropdownMenuItem(text = { Text(stringResource(R.string.scan_move_later)) }, enabled = index < count - 1, onClick = { menu = false; scan.shift(page.id, 1) })
                DropdownMenuItem(text = { Text(stringResource(R.string.scan_delete), color = MaterialTheme.colorScheme.error) }, enabled = !busy, onClick = { menu = false; scan.delete(page.id) })
            }
        }
    }
}

/** One page, large, to pinch and pan. */
@Composable
private fun PageViewer(page: ScanPage, onClose: () -> Unit) {
    val image = remember(page.id, page.jpeg) { BitmapFactory.decodeByteArray(page.jpeg, 0, page.jpeg.size)?.asImageBitmap() }
    var zoom by remember { mutableFloatStateOf(1f) }
    var shift by remember { mutableStateOf(Offset.Zero) }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            if (image != null) {
                Image(
                    image, null,
                    Modifier.fillMaxSize()
                        .pointerInput(Unit) {
                            detectTransformGestures { _, pan, change, _ ->
                                zoom = (zoom * change).coerceIn(1f, 5f)
                                val room = Offset(size.width * (zoom - 1) / 2, size.height * (zoom - 1) / 2)
                                shift = Offset((shift.x + pan.x).coerceIn(-room.x, room.x), (shift.y + pan.y).coerceIn(-room.y, room.y))
                            }
                        }
                        .graphicsLayer(scaleX = zoom, scaleY = zoom, translationX = shift.x, translationY = shift.y),
                    contentScale = ContentScale.Fit,
                )
            }
            IconButton(onClose, Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(8.dp).background(Color.Black.copy(alpha = 0.5f), CircleShape)) {
                Icon(painterResource(R.drawable.ic_close), stringResource(R.string.scan_close), tint = Color.White)
            }
        }
    }
}
