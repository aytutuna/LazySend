package com.lazysend.lazysend.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.platform.LocalLayoutDirection
import com.lazysend.lazysend.R
import com.lazysend.lazysend.scan.CornerAnswer
import com.lazysend.lazysend.scan.CornerEditorModel
import com.lazysend.lazysend.scan.CornerRequest
import com.lazysend.lazysend.scan.Pt
import com.lazysend.lazysend.scan.Rect as PhotoRect
import com.lazysend.lazysend.scan.RgbaImage
import com.lazysend.lazysend.scan.ViewSize
import java.nio.ByteBuffer
import kotlin.math.atan2
import kotlin.math.max
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private val Accent = Color(0xFF8C9EFF)

/** The editor over everything, for a shot the page was not found clearly in and for a page that is cut again from the page stack. */
@Composable
fun CornerEditorDialog(request: CornerRequest, onAnswer: (CornerAnswer) -> Unit) {
    Dialog(
        onDismissRequest = { onAnswer(CornerAnswer.Cancel) },
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Surface(Modifier.fillMaxSize()) { CornerEditor(request, onAnswer) }
    }
}

/**
 * Where the page is, for a look: the photo with the page's outline, four corners and the middle of each edge to drag, a magnifier
 * while one moves, pinch to zoom for the fine placing. The corners stay in the photo's pixels; everything here is drawn in dp.
 */
@Composable
fun CornerEditor(request: CornerRequest, onAnswer: (CornerAnswer) -> Unit) {
    val model = remember(request.id) { CornerEditorModel(request.photo.width, request.photo.height, request.corners) }
    // The model is plain state: this makes what reads it draw again after a change.
    var version by remember { mutableIntStateOf(0) }
    val changed = { version++; Unit }
    val image by produceState<ImageBitmap?>(null, request.id) {
        value = withContext(Dispatchers.Default) { request.photo.forDisplay().asImageBitmap() }
    }

    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton({ onAnswer(CornerAnswer.Cancel) }) {
                Text(stringResource(if (request.replacing == null) R.string.corners_retake else R.string.cancel))
            }
            Text(stringResource(R.string.corners_title), Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
            TextButton({ onAnswer(CornerAnswer.Use(model.corners)) }, enabled = model.canUseCorners) { Text(stringResource(R.string.corners_use)) }
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (request.replacing == null) Text(stringResource(R.string.corners_reason), style = MaterialTheme.typography.bodyMedium)
            Text(stringResource(R.string.corners_hint), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
        }
        // The photo's left is the photo's left whatever the language.
        CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
            Box(Modifier.weight(1f).fillMaxWidth()) { Stage(model, image, version, changed) }
        }
        Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            OutlinedButton({ model.reset(); changed() }, enabled = model.canReset) { Text(stringResource(R.string.corners_reset)) }
            OutlinedButton({ onAnswer(CornerAnswer.Whole) }) { Text(stringResource(R.string.corners_whole)) }
        }
    }
}

@Composable
private fun Stage(model: CornerEditorModel, image: ImageBitmap?, version: Int, changed: () -> Unit) {
    val density = LocalDensity.current.density
    var pixels by remember { mutableStateOf(IntSize.Zero) }
    val size = ViewSize(pixels.width / density.toDouble(), pixels.height / density.toDouble())
    val frame = model.shownFrame(size)
    val latest by rememberUpdatedState(size)
    val stageLabel = stringResource(R.string.corners_stage)

    Box(
        Modifier.fillMaxSize().clipToBounds().background(Color.Black.copy(alpha = 0.85f)).onSizeChanged { pixels = it }
            .semantics { contentDescription = stageLabel }
            .focusable()
            .onKeyEvent { key -> moveByKey(model, key, changed) }
            .pointerInput(model, density) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val from = down.position.pt(density)
                    var pinching = false
                    var startSpan = 1f
                    model.touchMoved(from, from, model.shownFrame(latest), latest)
                    changed()
                    do {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.filter { it.pressed }
                        if (pressed.size >= 2 && !pinching && model.dragging == null) {
                            model.beginPinch()
                            pinching = true
                            startSpan = max(span(pressed), 1f)
                        }
                        if (pinching) {
                            if (pressed.size >= 2) model.pinch(span(pressed) / startSpan.toDouble(), centre(pressed).pt(density), latest)
                        } else {
                            event.changes.firstOrNull { it.id == down.id && it.pressed }?.let {
                                model.touchMoved(from, it.position.pt(density), model.shownFrame(latest), latest)
                            }
                        }
                        event.changes.forEach { it.consume() }
                        changed()
                    } while (event.changes.any { it.pressed })
                    model.touchEnded()
                    model.endPinch()
                    changed()
                }
            },
    ) {
        Canvas(Modifier.fillMaxSize()) {
            scale(density, density, pivot = Offset.Zero) { drawStage(model, image, size, version) }
        }
        if (image == null) CircularProgressIndicator(Modifier.align(Alignment.Center), color = Color.White)
        if (pixels != IntSize.Zero) Handles(model, frame, density, changed)
    }
}

private fun Offset.pt(density: Float) = Pt((x / density).toDouble(), (y / density).toDouble())

private fun span(pressed: List<PointerInputChange>) = (pressed[0].position - pressed[1].position).getDistance()

private fun centre(pressed: List<PointerInputChange>) = (pressed[0].position + pressed[1].position) / 2f

/** The arrow keys move the corner picked last (a smaller step with Shift held), 1 to 4 pick a corner. */
private fun moveByKey(model: CornerEditorModel, event: androidx.compose.ui.input.key.KeyEvent, changed: () -> Unit): Boolean {
    if (event.type != KeyEventType.KeyDown) return false
    val fine = !event.isShiftPressed
    when (event.key) {
        Key.DirectionLeft -> model.shift(model.selected, -1, 0, fine)
        Key.DirectionRight -> model.shift(model.selected, 1, 0, fine)
        Key.DirectionUp -> model.shift(model.selected, 0, -1, fine)
        Key.DirectionDown -> model.shift(model.selected, 0, 1, fine)
        Key.One -> model.select(0)
        Key.Two -> model.select(1)
        Key.Three -> model.select(2)
        Key.Four -> model.select(3)
        else -> return false
    }
    changed()
    return true
}

/**
 * The photo, the page's outline over it with the rest dimmed, the handles and, while a corner moves, the magnifier. [version] is
 * not read: it is what makes the model's changes draw again.
 */
@Suppress("UNUSED_PARAMETER")
private fun DrawScope.drawStage(model: CornerEditorModel, image: ImageBitmap?, size: ViewSize, version: Int) {
    val frame = model.shownFrame(size)
    if (image != null) drawPhoto(image, frame.x, frame.y, frame.width, frame.height)
    val points = model.viewCorners(frame)
    val outline = Path().apply {
        points.forEachIndexed { i, p -> if (i == 0) moveTo(p.x.toFloat(), p.y.toFloat()) else lineTo(p.x.toFloat(), p.y.toFloat()) }
        close()
    }
    val dim = Path().apply {
        fillType = PathFillType.EvenOdd
        addRect(Rect(frame.x.toFloat(), frame.y.toFloat(), (frame.x + frame.width).toFloat(), (frame.y + frame.height).toFloat()))
        addPath(outline)
    }
    drawPath(dim, Color.Black.copy(alpha = 0.35f))
    drawPath(outline, Accent, style = Stroke(2f))
    for (index in 0 until 4) {
        val big = index == model.selected || index == model.dragging
        val centre = points[index].offset()
        val radius = (if (big) 26f else 20f) / 2
        drawCircle(Accent.copy(alpha = 0.35f), radius, centre)
        drawCircle(Color.White, radius - 1f, centre, style = Stroke(if (big) 3f else 2f))
    }
    for (index in model.shownEdges(frame)) {
        val a = points[index and 3]
        val b = points[(index + 1) and 3]
        val big = index == model.selected || index == model.dragging
        val width = if (big) 28f else 22f
        val height = if (big) 11f else 8f
        val middle = Offset(((a.x + b.x) / 2).toFloat(), ((a.y + b.y) / 2).toFloat())
        val angle = Math.toDegrees(atan2(b.y - a.y, b.x - a.x)).toFloat()
        rotate(angle, middle) {
            val topLeft = Offset(middle.x - width / 2, middle.y - height / 2)
            drawRoundRect(Accent.copy(alpha = 0.35f), topLeft, Size(width, height), CornerRadius(height / 2))
            drawRoundRect(Color.White, topLeft, Size(width, height), CornerRadius(height / 2), Stroke(if (big) 3f else 2f))
        }
    }
    if (model.showsLoupe && image != null) drawLoupe(model, image, frame, size)
}

private fun Pt.offset() = Offset(x.toFloat(), y.toFloat())

private fun DrawScope.drawPhoto(image: ImageBitmap, x: Double, y: Double, width: Double, height: Double) {
    translate(x.toFloat(), y.toFloat()) {
        scale((width / image.width).toFloat(), (height / image.height).toFloat(), pivot = Offset.Zero) {
            drawImage(image, filterQuality = FilterQuality.High)
        }
    }
}

/** The magnifier over the moved corner, diagonally away from the page's middle. */
private fun DrawScope.drawLoupe(model: CornerEditorModel, image: ImageBitmap, frame: PhotoRect, size: ViewSize) {
    val centre = model.loupeCenter(frame, size).offset()
    val fitted = model.fittedFrame(size)
    val shift = model.loupeImageOffset(fitted)
    val side = CornerEditorModel.LOUPE_SIZE.toFloat()
    val round = Path().apply { addOval(Rect(centre, side / 2)) }
    clipPath(round) {
        drawCircle(Color.Black, side / 2, centre)
        drawPhoto(
            image, centre.x - side / 2 + shift.width, centre.y - side / 2 + shift.height,
            fitted.width * CornerEditorModel.LOUPE_ZOOM, fitted.height * CornerEditorModel.LOUPE_ZOOM,
        )
    }
    drawCircle(Accent, side / 2, centre, style = Stroke(2f))
    drawLine(Accent, Offset(centre.x, centre.y - 14), Offset(centre.x, centre.y + 14), 1f)
    drawLine(Accent, Offset(centre.x - 14, centre.y), Offset(centre.x + 14, centre.y), 1f)
}

/**
 * The handles for a screen reader: an invisible 44 dp spot on each corner and edge, which says where it is and moves one step
 * with its actions. Touches go past them to the stage.
 */
@Composable
private fun Handles(model: CornerEditorModel, frame: PhotoRect, density: Float, changed: () -> Unit) {
    val corners = listOf(R.string.corner_top_left, R.string.corner_top_right, R.string.corner_bottom_right, R.string.corner_bottom_left)
    val edges = listOf(R.string.edge_top, R.string.edge_right, R.string.edge_bottom, R.string.edge_left)
    for (index in 0 until 8) {
        val at = model.handlePoint(index, frame)
        val label: String
        val value: String
        val actions: List<CustomAccessibilityAction>
        if (index < 4) {
            label = stringResource(corners[model.cornerPlace(index)])
            val (left, top) = model.cornerPercents(index)
            value = stringResource(R.string.percent_corner, left, top)
            actions = listOf(
                act(R.string.move_left, changed) { model.shift(index, -1, 0) },
                act(R.string.move_right, changed) { model.shift(index, 1, 0) },
                act(R.string.move_up, changed) { model.shift(index, 0, -1) },
                act(R.string.move_down, changed) { model.shift(index, 0, 1) },
            )
        } else {
            val side = model.edgeSide(index)
            label = stringResource(edges[side])
            value = stringResource(listOf(R.string.percent_top, R.string.percent_right, R.string.percent_bottom, R.string.percent_left)[side], model.edgePercent(index))
            actions = listOf(
                act(R.string.move_out, changed) { model.nudgeEdge(index, true) },
                act(R.string.move_in, changed) { model.nudgeEdge(index, false) },
            )
        }
        Box(
            Modifier.offset { IntOffset(((at.x - 22) * density).roundToInt(), ((at.y - 22) * density).roundToInt()) }.size(44.dp)
                .semantics { contentDescription = label; stateDescription = value; customActions = actions },
        )
    }
}

@Composable
private fun act(label: Int, changed: () -> Unit, move: () -> Unit) = CustomAccessibilityAction(stringResource(label)) {
    move()
    changed()
    true
}

/** The photo made at most 4096 pixels long, so a 12 MP photo is shown whole and the magnifier zooms its own pixels. */
private fun RgbaImage.forDisplay(): Bitmap {
    val long = max(width, height)
    val shown = if (long <= 4096) this else (4096.0 / long).let { resized(max(1, (width * it).toInt()), max(1, (height * it).toInt())) }
    return Bitmap.createBitmap(shown.width, shown.height, Bitmap.Config.ARGB_8888).also { it.copyPixelsFromBuffer(ByteBuffer.wrap(shown.pixels)) }
}
