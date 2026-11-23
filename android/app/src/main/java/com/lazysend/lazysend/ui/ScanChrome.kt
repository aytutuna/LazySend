package com.lazysend.lazysend.ui

import androidx.annotation.StringRes
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.lazysend.lazysend.R
import com.lazysend.lazysend.data.TimelineEntry
import com.lazysend.lazysend.scan.CaptureFilter
import com.lazysend.lazysend.scan.CapturePlacement
import com.lazysend.lazysend.scan.CaptureQuality
import com.lazysend.lazysend.scan.CaptureState
import com.lazysend.lazysend.scan.LiveQuadUpdate
import com.lazysend.lazysend.scan.OutlineMapping
import com.lazysend.lazysend.scan.PreviewScale
import com.lazysend.lazysend.scan.ScanModel
import com.lazysend.lazysend.scan.ScanPage
import com.lazysend.lazysend.scan.ScanProblem

private val Green = Color(0xFF34C759)
private val Yellow = Color(0xFFFFCC00)

/** The analysis frame as the camera gives it: its size before any turn, and the clockwise turn that makes it upright. */
class FrameInfo(val rotation: Int, val width: Int, val height: Int)

fun filterName(filter: CaptureFilter): Int = when (filter) {
    CaptureFilter.Enhanced -> R.string.scan_filter_enhanced
    CaptureFilter.Original -> R.string.scan_filter_original
    CaptureFilter.Grayscale -> R.string.scan_filter_grayscale
    CaptureFilter.BlackAndWhite -> R.string.scan_filter_bw
    CaptureFilter.Whiteboard -> R.string.scan_filter_whiteboard
}

@Composable
fun problemText(problem: ScanProblem): String = when (problem) {
    is ScanProblem.Res -> stringResource(problem.id)
    is ScanProblem.Message -> problem.text
}

/** The count of pages as a phrase ("1 page", "3 pages"). */
@Composable
fun pagesText(count: Int): String = LocalContext.current.resources.getQuantityString(R.plurals.scan_pages, count, count)

/**
 * What the page in view is waiting for, as the line over the picture: how it sits in the frame, or why a page that holds still is
 * not taken yet, or that it is about to be. Null when there is nothing to say.
 */
@StringRes
fun scanStatus(update: LiveQuadUpdate, auto: Boolean): Int? {
    val followed = update.outline != null && (update.state == CaptureState.Moving || update.state == CaptureState.Steadying)
    if (followed || update.placement == CapturePlacement.CutOff) {
        when (update.placement) {
            CapturePlacement.Far -> return R.string.scan_closer
            CapturePlacement.CutOff -> return R.string.scan_fit_page
            CapturePlacement.Fine -> {}
        }
    }
    if (auto && update.state == CaptureState.Steadying) {
        return when (update.quality) {
            CaptureQuality.Blurry -> if (update.suggestsShutter) R.string.scan_tap_shutter else R.string.scan_not_sharp
            CaptureQuality.Dark -> R.string.scan_too_dark
            CaptureQuality.Good -> R.string.scan_found
        }
    }
    return null
}

/** The outline of the page found, over the preview: green while it holds still, else yellow. */
@Composable
fun ScanOutline(scan: ScanModel, frame: () -> FrameInfo?) {
    val live by scan.live.collectAsState()
    Canvas(Modifier.fillMaxSize()) {
        val update = live ?: return@Canvas
        val outline = update.outline ?: return@Canvas
        val info = frame() ?: return@Canvas
        val corners = OutlineMapping.toView(outline, info.rotation, info.width, info.height, size.width.toDouble(), size.height.toDouble(), PreviewScale.Fit)
        val path = Path().apply {
            corners.forEachIndexed { i, c -> if (i == 0) moveTo(c.x.toFloat(), c.y.toFloat()) else lineTo(c.x.toFloat(), c.y.toFloat()) }
            close()
        }
        val color = if (update.isSteady) Green else Yellow
        drawPath(path, color.copy(alpha = 0.15f))
        drawPath(path, color, style = Stroke(3.dp.toPx(), join = StrokeJoin.Round))
    }
}

/**
 * The camera tab in scan mode, over the picture: Auto and the light, the line that says what the page in view is waiting for,
 * the Controls pill with its drawer, and the bottom row with the pages taken and the shutter.
 */
@Composable
fun ScanChrome(
    scan: ScanModel,
    targets: List<PcRow>,
    selected: String?,
    onSelect: (String) -> Unit,
    entries: List<TimelineEntry>,
    cameraReady: Boolean,
    auto: Boolean,
    onAuto: (Boolean) -> Unit,
    filter: CaptureFilter,
    onFilter: (CaptureFilter) -> Unit,
    hasTorch: Boolean,
    torch: Boolean,
    onTorch: (Boolean) -> Unit,
    onScanning: (Boolean) -> Unit,
    zoom: @Composable () -> Unit,
    onPages: () -> Unit,
) {
    val pages by scan.pages.collectAsState()
    val live by scan.live.collectAsState()
    val working by scan.working.collectAsState()
    val shotEditing by scan.shotEditing.collectAsState()
    val pageEditing by scan.pageEditing.collectAsState()
    val problem by scan.problem.collectAsState()
    val lastName by scan.lastName.collectAsState()
    val target = targets.firstOrNull { it.id == selected }
    val canShoot = cameraReady && target != null && !working && shotEditing == null && pageEditing == null
    var drawerOpen by rememberSaveable { mutableStateOf(false) }

    val sent = sentLine(lastName, entries, target?.name).takeIf { pages.isEmpty() }
    val hint = live?.takeIf { canShoot }?.let { scanStatus(it, auto) }
    val line = when {
        working -> stringResource(R.string.scan_cutting)
        sent != null -> sent
        hint != null -> stringResource(hint)
        else -> null
    }
    val progress = if (auto && canShoot && live?.state == CaptureState.Steadying) live?.progress?.toFloat() ?: 0f else 0f
    val ring by animateFloatAsState(progress, tween(100, easing = LinearEasing), label = "ring")

    Column(Modifier.fillMaxSize().statusBarsPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
        CameraTopBar(
            true,
            onScanning,
            start = {
                AutoChip(auto, onAuto)
                if (hasTorch) TorchButton(torch, onTorch)
            },
            end = { target?.let { TargetChip(it, targets, onSelect, Scrim, Color.White, showLink = true) } },
        )
        problem?.let { ProblemPill(problemText(it)) }
        line?.let { StatusPill(it) }
        Box(Modifier.weight(1f))
        zoom()
        ControlsHandle(drawerOpen) { drawerOpen = !drawerOpen }
        if (drawerOpen) ControlsDrawer(filter, onFilter, hasTorch, torch, onTorch)
        Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, top = 12.dp, bottom = 20.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                // Not while a shot is being cut out or the editor is up: that answer would open over the sheet.
                PagesStack(scan, pages, enabled = pages.isNotEmpty() && !working && shotEditing == null, onClick = onPages)
            }
            Shutter(canShoot, ring) { scan.shoot() }
            Box(Modifier.weight(1f))
        }
    }
}

@Composable
private fun AutoChip(auto: Boolean, onAuto: (Boolean) -> Unit) {
    val state = stringResource(if (auto) R.string.scan_on else R.string.scan_off)
    val hint = stringResource(R.string.scan_auto_hint)
    Text(
        stringResource(R.string.scan_auto),
        Modifier.clip(RoundedCornerShape(50))
            .background(if (auto) MaterialTheme.colorScheme.primary else Scrim)
            .semantics { stateDescription = state; contentDescription = hint }
            .selectable(auto, role = Role.Switch) { onAuto(!auto) }
            .heightIn(min = 36.dp)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        color = if (auto) MaterialTheme.colorScheme.onPrimary else Color.White,
        style = MaterialTheme.typography.labelLarge,
        maxLines = 1,
    )
}

@Composable
private fun TorchButton(on: Boolean, onTorch: (Boolean) -> Unit) {
    Box(Modifier.size(40.dp).clip(CircleShape).background(Scrim).clickable { onTorch(!on) }, contentAlignment = Alignment.Center) {
        Icon(
            painterResource(if (on) R.drawable.ic_flash_on else R.drawable.ic_flash_off),
            stringResource(if (on) R.string.scan_light_on else R.string.scan_light_off),
            tint = if (on) Color.Yellow else Color.White,
        )
    }
}

@Composable
private fun StatusPill(text: String) {
    Text(
        text,
        Modifier.padding(horizontal = 12.dp, vertical = 4.dp).background(Color.Black.copy(alpha = 0.75f), RoundedCornerShape(50)).padding(horizontal = 12.dp, vertical = 6.dp),
        color = Color.White,
        style = MaterialTheme.typography.bodyMedium,
    )
}

/** The Controls pill at the foot of the picture that shows or hides the drawer under it. */
@Composable
private fun ControlsHandle(open: Boolean, onToggle: () -> Unit) {
    val label = stringResource(if (open) R.string.scan_controls_hide else R.string.scan_controls_show)
    Box(Modifier.heightIn(min = 48.dp).clickable(onClickLabel = label, onClick = onToggle), contentAlignment = Alignment.Center) {
        Row(
            Modifier.clip(RoundedCornerShape(50))
                .background(if (open) MaterialTheme.colorScheme.primary else Color(0xFF262626))
                .border(1.dp, Color.White.copy(alpha = 0.3f), RoundedCornerShape(50))
                .padding(start = 14.dp, end = 8.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val color = if (open) MaterialTheme.colorScheme.onPrimary else Color.White
            Text(stringResource(R.string.scan_controls), color = color, style = MaterialTheme.typography.labelLarge)
            Icon(painterResource(R.drawable.ic_chevron_up), null, Modifier.size(20.dp).rotate(if (open) 180f else 0f), tint = color)
        }
    }
}

private enum class Group { Filter, Flash }

/** What the pill opens, over a dark panel: the filter new pages get and, where the phone has a light, the light. */
@Composable
private fun ControlsDrawer(filter: CaptureFilter, onFilter: (CaptureFilter) -> Unit, hasTorch: Boolean, torch: Boolean, onTorch: (Boolean) -> Unit) {
    var group by rememberSaveable { mutableStateOf(Group.Filter) }
    val shown = if (hasTorch) group else Group.Filter
    Column(
        Modifier.padding(horizontal = 16.dp).padding(bottom = 8.dp).fillMaxWidth().background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(14.dp)).padding(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (hasTorch) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Choice(R.string.scan_filter, shown == Group.Filter) { group = Group.Filter }
                Choice(R.string.scan_flash, shown == Group.Flash) { group = Group.Flash }
            }
        }
        when (shown) {
            Group.Filter -> Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CaptureFilter.displayOrder.forEach { Choice(filterName(it), it == filter) { onFilter(it) } }
            }
            Group.Flash -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Choice(R.string.scan_off, !torch) { onTorch(false) }
                Choice(R.string.scan_on, torch) { onTorch(true) }
            }
        }
    }
}

@Composable
private fun Choice(@StringRes label: Int, selected: Boolean, onClick: () -> Unit) {
    Text(
        stringResource(label),
        Modifier.clip(RoundedCornerShape(50))
            .background(if (selected) MaterialTheme.colorScheme.primary else Color.White.copy(alpha = 0.2f))
            .selectable(selected, role = Role.RadioButton, onClick = onClick)
            .heightIn(min = 36.dp)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        color = if (selected) MaterialTheme.colorScheme.onPrimary else Color.White,
        style = MaterialTheme.typography.labelLarge,
        maxLines = 1,
    )
}

/** The pages taken: the last on a card, a second card behind it once there are two, and the count on a badge. */
@Composable
private fun PagesStack(scan: ScanModel, pages: List<ScanPage>, enabled: Boolean, onClick: () -> Unit) {
    val count = pages.size
    val last = pages.lastOrNull()
    val thumb = last?.let { remember(it.id, it.jpeg) { scan.thumbnail(it) } }
    val label = pagesText(count)
    val hint = stringResource(R.string.scan_pages_hint)
    Box(
        Modifier.size(width = 70.dp, height = 72.dp)
            .alpha(if (enabled || count == 0) 1f else 0.4f)
            .semantics { contentDescription = "$label. $hint" }
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (thumb != null) {
            if (count > 1) {
                Box(Modifier.offset(x = 3.dp, y = (-2).dp).rotate(6f).size(width = 46.dp, height = 60.dp).background(Color.White.copy(alpha = 0.5f), RoundedCornerShape(6.dp)))
            }
            Box {
                Image(
                    thumb.asImageBitmap(), null,
                    Modifier.background(Color.White, RoundedCornerShape(6.dp)).padding(3.dp).size(width = 46.dp, height = 60.dp).clip(RoundedCornerShape(4.dp)),
                    contentScale = ContentScale.Crop,
                )
                Text(
                    count.toString(),
                    Modifier.align(Alignment.TopEnd).padding(4.dp).background(MaterialTheme.colorScheme.primary, RoundedCornerShape(50)).heightIn(min = 18.dp).padding(horizontal = 5.dp),
                    color = MaterialTheme.colorScheme.onPrimary,
                    style = MaterialTheme.typography.labelSmall,
                )
            }
        } else {
            Box(
                Modifier.size(width = 48.dp, height = 64.dp).drawBehind {
                    drawRoundRect(
                        Color.White.copy(alpha = 0.6f), cornerRadius = CornerRadius(6.dp.toPx()),
                        style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx()))),
                    )
                },
            )
        }
    }
}
