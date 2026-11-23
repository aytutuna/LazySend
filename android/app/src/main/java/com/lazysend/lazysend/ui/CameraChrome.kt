package com.lazysend.lazysend.ui

import androidx.camera.core.ImageCapture
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.lazysend.lazysend.R
import com.lazysend.lazysend.data.Direction
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.EntryState
import com.lazysend.lazysend.data.TimelineEntry
import com.lazysend.lazysend.transfer.PhotoFormat
import kotlinx.coroutines.delay

internal val Scrim = Color.Black.copy(alpha = 0.45f)

/** The Photo | Scan switch at the top of the camera tab; the segment in use is filled. */
@Composable
internal fun ModeSwitch(scanning: Boolean, onScanning: (Boolean) -> Unit) {
    Row(Modifier.clip(RoundedCornerShape(50)).background(Scrim)) {
        ModeSegment(R.string.mode_photo, !scanning) { onScanning(false) }
        ModeSegment(R.string.mode_scan, scanning) { onScanning(true) }
    }
}

@Composable
private fun ModeSegment(label: Int, selected: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.clip(RoundedCornerShape(50))
            .background(if (selected) MaterialTheme.colorScheme.primary else Color.Transparent)
            .selectable(selected, role = Role.Tab, onClick = onClick)
            .heightIn(min = 36.dp)
            .padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(stringResource(label), color = if (selected) MaterialTheme.colorScheme.onPrimary else Color.White, style = MaterialTheme.typography.labelLarge, maxLines = 1)
    }
}

/**
 * The bar over the picture: the switch exactly in the middle, a side each, which share what the switch leaves and are cut short
 * there so neither reaches it.
 */
@Composable
internal fun CameraTopBar(scanning: Boolean, onScanning: (Boolean) -> Unit, start: @Composable RowScope.() -> Unit, end: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.weight(1f).padding(end = 8.dp).clipToBounds(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
            content = start,
        )
        ModeSwitch(scanning, onScanning)
        Box(Modifier.weight(1f).padding(start = 8.dp), contentAlignment = Alignment.CenterEnd) { end() }
    }
}

@Composable
internal fun PhotoChrome(
    targets: List<PcRow>,
    selected: String?,
    onSelect: (String) -> Unit,
    hasFlash: Boolean,
    flash: Int,
    onFlash: () -> Unit,
    format: PhotoFormat,
    onFormat: (PhotoFormat) -> Unit,
    onScanning: (Boolean) -> Unit,
    problem: String?,
    zoom: @Composable () -> Unit,
    shot: Shot?,
    entries: List<TimelineEntry>,
    onHistory: () -> Unit,
    canShoot: Boolean,
    onShoot: () -> Unit,
    canFlip: Boolean,
    onFlip: () -> Unit,
) {
    val target = targets.firstOrNull { it.id == selected }
    Column(Modifier.fillMaxSize().statusBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
        CameraTopBar(
            false,
            onScanning,
            start = {
                if (hasFlash) FlashButton(flash, onFlash)
                FormatChip(format, onFormat)
            },
            end = { target?.let { TargetChip(it, targets, onSelect, Scrim, Color.White, showLink = true) } },
        )
        problem?.let { ProblemPill(it) }
        Box(Modifier.weight(1f))
        zoom()
        Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, top = 12.dp, bottom = 20.dp), verticalAlignment = Alignment.Top) {
            Box(Modifier.weight(1f), contentAlignment = Alignment.TopStart) { Thumb(shot, entries, target?.name, onHistory) }
            Shutter(canShoot, stringResource(R.string.camera_take_photo), onClick = onShoot)
            Box(Modifier.weight(1f), contentAlignment = Alignment.TopEnd) {
                Box(
                    Modifier.size(52.dp).alpha(if (canFlip) 1f else 0.4f).clip(CircleShape).background(Scrim).clickable(enabled = canFlip, onClick = onFlip),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(painterResource(R.drawable.ic_flip), stringResource(R.string.camera_flip), tint = Color.White)
                }
            }
        }
    }
}

@Composable
internal fun ProblemPill(text: String) {
    Text(
        text,
        Modifier.padding(8.dp).background(MaterialTheme.colorScheme.error, RoundedCornerShape(50)).padding(horizontal = 12.dp, vertical = 6.dp),
        color = MaterialTheme.colorScheme.onError,
        style = MaterialTheme.typography.bodySmall,
    )
}

internal fun nextFlash(mode: Int) = when (mode) {
    ImageCapture.FLASH_MODE_OFF -> ImageCapture.FLASH_MODE_AUTO
    ImageCapture.FLASH_MODE_AUTO -> ImageCapture.FLASH_MODE_ON
    else -> ImageCapture.FLASH_MODE_OFF
}

@Composable
private fun FlashButton(mode: Int, onClick: () -> Unit) {
    val (icon, label) = when (mode) {
        ImageCapture.FLASH_MODE_AUTO -> R.drawable.ic_flash_auto to R.string.flash_auto
        ImageCapture.FLASH_MODE_ON -> R.drawable.ic_flash_on to R.string.flash_on
        else -> R.drawable.ic_flash_off to R.string.flash_off
    }
    Box(Modifier.size(40.dp).clip(CircleShape).background(Scrim).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(painterResource(icon), stringResource(label), tint = if (mode == ImageCapture.FLASH_MODE_OFF) Color.White else Color.Yellow)
    }
}

@Composable
private fun FormatChip(format: PhotoFormat, onFormat: (PhotoFormat) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Text(
            formatLabel(format),
            Modifier.clip(RoundedCornerShape(50)).background(Scrim).clickable { open = true }.padding(horizontal = 12.dp, vertical = 8.dp),
            color = Color.White,
            style = MaterialTheme.typography.labelLarge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        DropdownMenu(open, { open = false }) {
            FormatItems(format) {
                open = false
                onFormat(it)
            }
        }
    }
}

@Composable
internal fun Panel(content: @Composable () -> Unit) {
    Column(
        Modifier.padding(16.dp).background(Color(0xFF2A2A2A), RoundedCornerShape(14.dp)).padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) { content() }
}

/** The shutter; [progress] fills a green ring round it, which is Auto's count while a page holds still. */
@Composable
internal fun Shutter(enabled: Boolean, label: String, progress: Float = 0f, onClick: () -> Unit) {
    Box(Modifier.size(76.dp).alpha(if (enabled) 1f else 0.4f), contentAlignment = Alignment.Center) {
        Box(Modifier.size(76.dp).border(4.dp, Color.White, CircleShape).padding(7.dp).clip(CircleShape).background(Color.White).semantics { contentDescription = label }.clickable(enabled = enabled, onClick = onClick))
        if (progress > 0f) {
            Canvas(Modifier.size(76.dp)) {
                val width = 4.dp.toPx()
                drawArc(
                    Color(0xFF34C759), -90f, 360f * progress.coerceAtMost(1f), false,
                    topLeft = Offset(width / 2, width / 2), size = Size(size.width - width, size.height - width),
                    style = Stroke(width, cap = StrokeCap.Round),
                )
            }
        }
    }
}

/**
 * How the last send went, for the line under a thumbnail or at the top: nothing until [name] was taken, waiting while its row
 * is on the way, and for a few seconds once it is delivered.
 */
@Composable
internal fun sentLine(name: String?, entries: List<TimelineEntry>, target: String?): String? {
    val entry = name?.let { n -> entries.firstOrNull { it.direction == Direction.Sent && it.kind == EntryKind.File && it.title == n } }
    var hidden by remember(name) { mutableStateOf(false) }
    LaunchedEffect(entry?.state, name) {
        if (entry?.state == EntryState.Done) {
            hidden = false
            delay(3000)
            hidden = true
        }
    }
    val who = entry?.pcName ?: target
    return when {
        name == null || who == null -> null
        entry?.state == EntryState.Done -> if (hidden) null else stringResource(R.string.camera_sent_to, who)
        entry?.state == EntryState.Failed -> stringResource(R.string.state_failed)
        else -> stringResource(R.string.camera_waiting, who)
    }
}

@Composable
private fun Thumb(shot: Shot?, entries: List<TimelineEntry>, target: String?, onClick: () -> Unit) {
    val line = sentLine(shot?.name, entries, target)
    Column(Modifier.clickable(onClick = onClick), horizontalAlignment = Alignment.Start) {
        Box(Modifier.size(52.dp).clip(RoundedCornerShape(8.dp)).background(Color.White.copy(alpha = 0.15f))) {
            shot?.thumbnail?.let { Image(it.asImageBitmap(), stringResource(R.string.camera_history), Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
        }
        if (line != null) Text(line, color = Color.White, style = MaterialTheme.typography.labelSmall, maxLines = 1)
    }
}
