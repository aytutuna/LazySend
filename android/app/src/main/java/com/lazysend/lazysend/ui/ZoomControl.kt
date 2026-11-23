package com.lazysend.lazysend.ui

import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.AwaitPointerEventScope
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lazysend.lazysend.R
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

private val ZoomAccent = Color(0xFFB9C3FF)
private val ZoomScrim = Color(0x59000000)

private suspend fun AwaitPointerEventScope.nextChange(id: PointerId): PointerInputChange =
    awaitPointerEvent(PointerEventPass.Initial).changes.first { it.id == id }

/**
 * The lens buttons in a capsule, as in the phone's own camera. Holding or dragging along it opens a wheel that sets the zoom
 * continuously and closes a moment after the finger lifts. [top] is the camera's highest zoom ratio.
 */
@Composable
fun ZoomControl(now: Float, stops: List<Float>, top: Float, onZoom: (Float) -> Unit) {
    val scope = rememberCoroutineScope()
    val haptic = LocalHapticFeedback.current
    val slop = LocalViewConfiguration.current.touchSlop
    val holdTime = LocalViewConfiguration.current.longPressTimeoutMillis
    val perDoubling = with(LocalDensity.current) { POINTS_PER_DOUBLING.dp.toPx() }
    val range = dialRange(stops, top)
    val liveNow by rememberUpdatedState(now)
    val liveRange by rememberUpdatedState(range)
    val liveStops by rememberUpdatedState(stops)
    val liveZoom by rememberUpdatedState(onZoom)
    var wheelOpen by remember { mutableStateOf(false) }
    var touching by remember { mutableStateOf(false) }
    var animation by remember { mutableStateOf<Job?>(null) }

    fun zoomTo(ratio: Float) {
        animation?.cancel()
        animation = scope.launch {
            animate(ln(liveNow), ln(ratio), animationSpec = tween(220)) { value, _ -> liveZoom(exp(value)) }
        }
    }

    LaunchedEffect(wheelOpen, touching) {
        if (wheelOpen && !touching) {
            delay(1500)
            wheelOpen = false
        }
    }

    val name = stringResource(R.string.zoom)
    Box(
        Modifier
            .semantics(mergeDescendants = true) {
                contentDescription = name
                stateDescription = zoomLabel(now)
                progressBarRangeInfo = ProgressBarRangeInfo(stops.indices.minBy { abs(stops[it] - now) }.toFloat(), 0f..(stops.size - 1).toFloat(), stops.size - 2)
                setProgress {
                    stops.getOrNull(it.roundToInt())?.let(::zoomTo)
                    true
                }
            }
            .height(52.dp)
            .pointerInput(perDoubling, slop) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    // A short press is left to the buttons; a hold or a move along the control takes it over.
                    val moved = withTimeoutOrNull(holdTime) {
                        var drag = false
                        var up = false
                        while (!drag && !up) {
                            val change = nextChange(down.id)
                            up = !change.pressed
                            drag = abs(change.position.x - down.position.x) > slop
                        }
                        drag
                    }
                    if (moved == false) return@awaitEachGesture
                    animation?.cancel()
                    touching = true
                    wheelOpen = true
                    try {
                        val start = liveNow
                        var last = start
                        while (true) {
                            val change = nextChange(down.id)
                            change.consume()
                            if (!change.pressed) break
                            val zoom = zoomAfterDrag(start, change.position.x - down.position.x, perDoubling, liveRange)
                            if (crossesStop(last, zoom, liveStops)) haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                            last = zoom
                            liveZoom(zoom)
                        }
                    } finally {
                        touching = false
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        if (wheelOpen) Wheel(now, stops, range, perDoubling) else Capsule(now, stops, ::zoomTo)
    }
}

@Composable
private fun Capsule(now: Float, stops: List<Float>, onStop: (Float) -> Unit) {
    val current = stops.lastOrNull { it <= now + 0.01f }
    Row(
        Modifier.background(ZoomScrim, CircleShape).padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        stops.forEach { value ->
            val active = value == current
            Box(
                Modifier.size(if (active) 40.dp else 32.dp).background(Color.Black.copy(alpha = if (active) 0.55f else 0.2f), CircleShape)
                    .clickable { if (abs(now - value) > 0.01f) onStop(value) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (active) zoomLabel(now) else stopLabel(value),
                    color = if (active) ZoomAccent else Color.White,
                    fontSize = if (active) 14.sp else 12.sp,
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun Wheel(now: Float, stops: List<Float>, range: ClosedFloatingPointRange<Float>, perDoubling: Float) {
    val measurer = rememberTextMeasurer()
    val labelStyle = MaterialTheme.typography.labelSmall
    val marks = remember(range, stops) { wheelTicks(range, stops) }
    Box(contentAlignment = Alignment.Center) {
        Canvas(Modifier.width(260.dp).height(52.dp).background(ZoomScrim, CircleShape)) {
            val middle = size.width / 2
            marks.forEach { mark ->
                val x = middle + wheelOffset(mark, now, perDoubling)
                val fade = ((middle - abs(x - middle)) / (middle * 0.3f)).coerceIn(0f, 1f)
                if (fade == 0f) return@forEach
                val major = stops.any { abs(it - mark) < 0.001f }
                val height = (if (major) 24.dp else 16.dp).toPx()
                drawLine(Color.White.copy(alpha = (if (major) 0.9f else 0.5f) * fade), Offset(x, size.height - height), Offset(x, size.height - 8.dp.toPx()), if (major) 1.5.dp.toPx() else 1.dp.toPx())
                if (major) {
                    val label = measurer.measure(stopLabel(mark), labelStyle.copy(color = Color.White.copy(alpha = fade)))
                    drawText(label, topLeft = Offset(x - label.size.width / 2, 6.dp.toPx()))
                }
            }
            drawLine(ZoomAccent, Offset(middle, size.height - 28.dp.toPx()), Offset(middle, size.height - 6.dp.toPx()), 2.dp.toPx(), StrokeCap.Round)
        }
        Text(
            zoomLabel(now),
            Modifier.offset(y = (-38).dp).background(ZoomScrim, CircleShape).padding(horizontal = 10.dp, vertical = 3.dp),
            color = ZoomAccent,
            style = MaterialTheme.typography.labelLarge,
        )
    }
}
