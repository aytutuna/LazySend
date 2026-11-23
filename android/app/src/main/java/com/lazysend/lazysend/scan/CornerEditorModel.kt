package com.lazysend.lazysend.scan

import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** A width and a height in view units; also an offset. */
data class ViewSize(val width: Double, val height: Double) {
    companion object {
        val Zero = ViewSize(0.0, 0.0)
    }
}

private val Rect.minX get() = x
private val Rect.minY get() = y
private val Rect.maxX get() = x + width
private val Rect.maxY get() = y + height
private val Rect.midX get() = x + width / 2
private val Rect.midY get() = y + height / 2

/**
 * What the corner editor shows and does, without a screen: the photo fitted into the view (and zoomed and
 * panned), the four corners (in the photo's pixels, top-left origin) and which handle a finger moves (a
 * corner, or the middle of an edge, which moves both of its corners), and where the magnifier sits.
 * `PageFinder.movedCorner` keeps the corners in the photo and on a convex outline; the magnifier sits
 * diagonally away from the page's middle, and a corner moves by how far the finger moves, so it is never
 * hidden under the finger. Handles: 0 to 3 a corner, 4 to 7 the middle of the edge from corner 0 to 1, 1 to
 * 2, 2 to 3 and 3 to 0.
 */
class CornerEditorModel(photoWidth: Int, photoHeight: Int, val start: Quad) {
    val photoWidth = max(photoWidth, 1)
    val photoHeight = max(photoHeight, 1)

    /** The corners as placed (0 top-left ... 3 bottom-left, as placed). */
    var corners: Quad = start
        private set

    /** The handle the magnifier shows and the last one moved. */
    var selected = 0
        private set

    /** The handle a finger is moving, if any. */
    var dragging: Int? = null
        private set

    /** Where the moved corner was when the finger came down, in the photo's pixels. */
    private var dragOrigin = Pt(0.0, 0.0)

    /** The same for the two corners of a moved edge. */
    private var edgeOrigin: List<Pt> = emptyList()

    /** How far the photo is zoomed (1 to `MAX_ZOOM`) and how far it is moved from the view's middle. */
    var zoom = 1.0
        private set
    var pan = ViewSize.Zero
        private set
    private var zoomOrigin = 1.0
    private var panOrigin = ViewSize.Zero

    /** Where the touch handled now came down, so a new touch is told from the old one after a cancel. */
    private var touchStart: Pt? = null

    /** A finger moves the photo (it came down away from every handle while zoomed in). */
    private var panning = false

    /** A pinch is under way. */
    var isPinching = false
        private set

    /** The magnifier shows while a corner is moved. */
    val showsLoupe: Boolean get() = dragging != null

    /** Reset would change the corners. */
    val canReset: Boolean get() = corners != start || zoom != 1.0 || pan != ViewSize.Zero

    /** The page can be cut out along the corners (`PageFinder.canUseCorners`). */
    val canUseCorners: Boolean get() = PageFinder.canUseCorners(corners)

    /** Back to the corners the editor opened with, and the photo unzoomed. */
    fun reset() {
        corners = start
        dragging = null
        panning = false
        zoom = 1.0
        pan = ViewSize.Zero
    }

    /** The photo fitted into a view of `size`, `INSET` in from each side, centered (aspect fit). */
    fun fittedFrame(size: ViewSize): Rect {
        val boundsWidth = size.width - 2 * INSET
        val boundsHeight = size.height - 2 * INSET
        if (!(boundsWidth > 0 && boundsHeight > 0)) return Rect(0.0, 0.0, 0.0, 0.0)
        val w = photoWidth.toDouble()
        val h = photoHeight.toDouble()
        val scale = min(boundsWidth / w, boundsHeight / h)
        val fittedWidth = w * scale
        val fittedHeight = h * scale
        return Rect(INSET + boundsWidth / 2 - fittedWidth / 2, INSET + boundsHeight / 2 - fittedHeight / 2,
            fittedWidth, fittedHeight)
    }

    /**
     * The photo as shown: the fitted frame zoomed about the view's middle and moved by the pan. Handles,
     * the outline and the magnifier are drawn into it; the corners stay in the photo's pixels.
     */
    fun shownFrame(size: ViewSize): Rect = zoomed(fittedFrame(size), zoom, pan, size)

    /** `pan` kept so the photo still covers the view's middle at `zoom`; none while the photo is not zoomed. */
    private fun clampedPan(pan: ViewSize, zoom: Double, size: ViewSize): ViewSize {
        if (!(zoom > 1)) return ViewSize.Zero
        val base = fittedFrame(size)
        val middleX = size.width / 2
        val middleY = size.height / 2
        return ViewSize(
            min(max(pan.width, -(base.maxX - middleX) * zoom), -(base.minX - middleX) * zoom),
            min(max(pan.height, -(base.maxY - middleY) * zoom), -(base.minY - middleY) * zoom))
    }

    /** A point of the photo (pixels) in the view. */
    fun viewPoint(imagePoint: Pt, frame: Rect): Pt =
        Pt(frame.minX + imagePoint.x / photoWidth.toDouble() * frame.width,
            frame.minY + imagePoint.y / photoHeight.toDouble() * frame.height)

    /** A point of the view in the photo (pixels). */
    fun imagePoint(viewPoint: Pt, frame: Rect): Pt {
        if (!(frame.width > 0 && frame.height > 0)) return Pt(0.0, 0.0)
        return Pt((viewPoint.x - frame.minX) / frame.width * photoWidth.toDouble(),
            (viewPoint.y - frame.minY) / frame.height * photoHeight.toDouble())
    }

    /** The corners in the view, in order. */
    fun viewCorners(frame: Rect): List<Pt> = (0 until 4).map { viewPoint(corners[it], frame) }

    /** Where handle `index` sits in the view: a corner, or the middle of an edge. */
    fun handlePoint(index: Int, frame: Rect): Pt {
        if (index < 4) return viewPoint(corners[index], frame)
        val a = viewPoint(corners[index and 3], frame)
        val b = viewPoint(corners[index + 1], frame)
        return Pt((a.x + b.x) / 2, (a.y + b.y) / 2)
    }

    /**
     * The edge handles (4 to 7) that are drawn and can be taken: an edge too short to keep its middle
     * clear of both corners leaves the corners to be picked.
     */
    fun shownEdges(frame: Rect): List<Int> = (4 until 8).filter { index ->
        val a = viewPoint(corners[index and 3], frame)
        val b = viewPoint(corners[index + 1], frame)
        hypot(a.x - b.x, a.y - b.y) / 2 > EDGE_HIT_RADIUS
    }

    /** The handle under `location` (the nearest when handles overlap); null for none. A corner in reach wins over an edge. */
    fun handle(location: Pt, frame: Rect): Int? {
        var best: Int? = null
        var bestDistance = HANDLE_HIT_RADIUS
        for (index in 0 until 4) {
            val point = handlePoint(index, frame)
            val distance = hypot(point.x - location.x, point.y - location.y)
            if (distance < bestDistance || (best == null && distance <= bestDistance)) {
                bestDistance = distance
                best = index
            }
        }
        if (best != null) return best
        bestDistance = EDGE_HIT_RADIUS
        for (index in shownEdges(frame)) {
            val point = handlePoint(index, frame)
            val distance = hypot(point.x - location.x, point.y - location.y)
            if (distance < bestDistance || (best == null && distance <= bestDistance)) {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /** A finger came down at `location`: the handle under it, if any, starts moving. False when no handle is there. */
    fun beginDrag(location: Pt, frame: Rect): Boolean {
        val index = handle(location, frame) ?: return false
        dragging = index
        selected = index
        if (index < 4) {
            dragOrigin = corners[index]
        } else {
            edgeOrigin = listOf(corners[index and 3], corners[index + 1])
        }
        return true
    }

    /**
     * The finger that came down at `from` is at `location`: the corner moves by as much (in the photo's
     * pixels), kept within the photo and on a convex outline. An edge moves along its normal by the
     * finger's part along it, both of its corners together.
     */
    fun drag(from: Pt, location: Pt, frame: Rect) {
        val index = dragging ?: return
        if (!(frame.width > 0 && frame.height > 0)) return
        val dx = (location.x - from.x) / frame.width * photoWidth.toDouble()
        val dy = (location.y - from.y) / frame.height * photoHeight.toDouble()
        if (index < 4) {
            val target = Pt(dragOrigin.x + dx, dragOrigin.y + dy)
            corners = PageFinder.movedCorner(corners, index, target, photoWidth, photoHeight)
            return
        }
        val normal = normal(edgeOrigin[0], edgeOrigin[1]) ?: return
        moveEdge(index, edgeOrigin, dx * normal.x + dy * normal.y)
    }

    /** The finger lifted, or the touch was cancelled. */
    fun endDrag() {
        dragging = null
        panning = false
    }

    /**
     * A touch that came down at `from` is at `location`. A touch that differs from the one handled ends
     * that one first (a cancelled touch never reports its end), then takes the handle under it, or moves
     * the zoomed photo when none is there.
     */
    fun touchMoved(from: Pt, location: Pt, frame: Rect, size: ViewSize) {
        if (touchStart != from) {
            endDrag()
            touchStart = from
            if (!isPinching && !beginDrag(from, frame) && zoom > 1) {
                panning = true
                panOrigin = pan
            }
        }
        if (dragging != null) {
            drag(from, location, frame)
        } else if (panning) {
            val moved = ViewSize(panOrigin.width + location.x - from.x, panOrigin.height + location.y - from.y)
            pan = clampedPan(moved, zoom, size)
        }
    }

    /** The touch ended or was cancelled. */
    fun touchEnded() {
        endDrag()
        touchStart = null
    }

    /** A pinch starts; one that comes while a handle is held is ignored. */
    fun beginPinch() {
        if (dragging != null) return
        isPinching = true
        panning = false
        zoomOrigin = zoom
        panOrigin = pan
    }

    /** The pinch is at `scale` of where it began: the photo is zoomed by as much about `anchor`, which stays over the same point of the photo. */
    fun pinch(scale: Double, anchor: Pt, size: ViewSize) {
        if (!isPinching) return
        val base = fittedFrame(size)
        val from = zoomed(base, zoomOrigin, panOrigin, size)
        val target = min(max(zoomOrigin * scale, 1.0), MAX_ZOOM)
        val ratio = target / zoomOrigin
        val originX = anchor.x - (anchor.x - from.minX) * ratio
        val originY = anchor.y - (anchor.y - from.minY) * ratio
        val plain = zoomed(base, target, ViewSize.Zero, size)
        val moved = ViewSize(originX - plain.minX, originY - plain.minY)
        zoom = target
        pan = clampedPan(moved, target, size)
    }

    fun endPinch() {
        isPinching = false
    }

    /**
     * Edge handle `index` moved `wanted` along its normal from where its corners were (`origin`): as far as
     * keeps both in the photo and on a convex outline, the corners moved in turn by `PageFinder.movedCorner`;
     * the edge stays parallel to where it was, so it stops where either corner would be held back.
     */
    private fun moveEdge(index: Int, origin: List<Pt>, wanted: Double) {
        val normal = normal(origin[0], origin[1]) ?: return
        var low = -Double.MAX_VALUE
        var high = Double.MAX_VALUE
        for (point in origin) {
            val starts = doubleArrayOf(point.x, point.y)
            val steps = doubleArrayOf(normal.x, normal.y)
            val limits = doubleArrayOf(photoWidth.toDouble(), photoHeight.toDouble())
            for (axis in 0 until 2) {
                if (steps[axis] != 0.0 && starts[axis] > 0 && starts[axis] < limits[axis]) {
                    val toZero = -starts[axis] / steps[axis]
                    val toLimit = (limits[axis] - starts[axis]) / steps[axis]
                    low = max(low, min(toZero, toLimit))
                    high = min(high, max(toZero, toLimit))
                }
            }
        }
        val full = min(max(wanted, low), high)
        val a = index and 3
        val b = (index + 1) and 3
        val points = corners.corners.toMutableList()
        points[a] = origin[0]
        points[b] = origin[1]
        val base = Quad(points[0], points[1], points[2], points[3])
        val width = photoWidth
        val height = photoHeight

        fun tried(t: Double): Quad? {
            val first = Pt(min(max(origin[0].x + t * normal.x, 0.0), width.toDouble()),
                min(max(origin[0].y + t * normal.y, 0.0), height.toDouble()))
            val second = Pt(min(max(origin[1].x + t * normal.x, 0.0), width.toDouble()),
                min(max(origin[1].y + t * normal.y, 0.0), height.toDouble()))
            val one = PageFinder.movedCorner(base, a, first, width, height)
            val two = PageFinder.movedCorner(one, b, second, width, height)
            val landed = hypot(two[a].x - first.x, two[a].y - first.y) < 1e-6 &&
                hypot(two[b].x - second.x, two[b].y - second.y) < 1e-6
            return if (landed) two else null
        }

        val whole = tried(full)
        if (whole != null) {
            corners = whole
            return
        }
        var good = 0.0
        var bad = full
        var best = base
        repeat(12) {
            val middle = (good + bad) / 2
            val moved = tried(middle)
            if (moved != null) {
                good = middle
                best = moved
            } else {
                bad = middle
            }
        }
        corners = best
    }

    /**
     * Where the magnifier's center sits for the selected corner in a view of `size`: diagonally away from
     * the page's middle, else the first other diagonal that keeps it in the view.
     */
    fun loupeCenter(frame: Rect, size: ViewSize): Pt {
        val points = viewCorners(frame)
        val corner = handlePoint(selected, frame)
        var sumX = 0.0
        var sumY = 0.0
        for (point in points) {
            sumX += point.x
            sumY += point.y
        }
        return loupeCenter(corner, Pt(sumX / 4, sumY / 4), size)
    }

    /**
     * The offset of the magnified photo inside the magnifier, so the selected handle is at its center;
     * `frame` is the fitted photo, which the magnifier scales by `LOUPE_ZOOM`.
     */
    fun loupeImageOffset(frame: Rect): ViewSize {
        val corner = handlePoint(selected, frame)
        return ViewSize(LOUPE_SIZE / 2 - (corner.x - frame.minX) * LOUPE_ZOOM,
            LOUPE_SIZE / 2 - (corner.y - frame.minY) * LOUPE_ZOOM)
    }

    /**
     * Where corner `index` sits once the outline's corners are named again by `Quad.fromCorners` (0 top
     * left ... 3 bottom left), so a corner dragged round to the page's top right is the top right one. Each
     * corner gets a place of its own, also when two of them meet. For screen readers' names.
     */
    fun cornerPlace(index: Int): Int = place(index and 3)

    /** The side of the page edge handle `index` (4 to 7) is on now: 0 top, 1 right, 2 bottom, 3 left. */
    fun edgeSide(index: Int): Int {
        val a = place(index and 3)
        val b = place((index + 1) and 3)
        return when (min(a, b) to max(a, b)) {
            0 to 1 -> 0
            1 to 2 -> 1
            2 to 3 -> 2
            else -> 3
        }
    }

    /** Where corner `index` is, in percent of the photo's width and height: (from the left, from the top). */
    fun cornerPercents(index: Int): Pair<Int, Int> {
        val point = corners[index and 3]
        val left = roundHalfAway(point.x / photoWidth.toDouble() * 100).toInt()
        val top = roundHalfAway(point.y / photoHeight.toDouble() * 100).toInt()
        return left to top
    }

    /** How far the middle of edge handle `index` is from the side it is named for (`edgeSide`), in percent of the photo. */
    fun edgePercent(index: Int): Int {
        val a = corners[index and 3]
        val b = corners[index + 1]
        val x = (a.x + b.x) / 2 / photoWidth.toDouble() * 100
        val y = (a.y + b.y) / 2 / photoHeight.toDouble() * 100
        return when (edgeSide(index)) {
            0 -> roundHalfAway(y).toInt()
            1 -> roundHalfAway(100 - x).toInt()
            2 -> roundHalfAway(100 - y).toInt()
            else -> roundHalfAway(x).toInt()
        }
    }

    private fun place(wanted: Int): Int {
        val points = corners.corners
        val named = Quad.fromCorners(points).corners
        val taken = BooleanArray(4)
        var place = wanted
        for (slot in 0 until 4) {
            for (original in 0 until 4) {
                if (!taken[original] && points[original] == named[slot]) {
                    taken[original] = true
                    if (original == wanted) place = slot
                    break
                }
            }
        }
        return place
    }

    /** Corner `index` moved one step with a screen reader's swipe up or down: `outward` away from the page's middle, else towards it, a hundredth of the photo's long side along both axes. */
    fun nudge(index: Int, outward: Boolean) {
        var sumX = 0.0
        var sumY = 0.0
        for (point in corners.corners) {
            sumX += point.x
            sumY += point.y
        }
        val at = corners[index and 3]
        val step = max(photoWidth, photoHeight).toDouble() / 100
        val sign = if (outward) 1.0 else -1.0
        val dx = if (at.x >= sumX / 4) sign * step else -sign * step
        val dy = if (at.y >= sumY / 4) sign * step else -sign * step
        selected = index and 3
        corners = PageFinder.movedCorner(corners, index and 3, Pt(at.x + dx, at.y + dy), photoWidth, photoHeight)
    }

    /**
     * Corner `index` moved along one axis: `dx` and `dy` are -1, 0 or 1 steps of a hundredth of the photo's
     * long side (a fifth of that when `fine`), for named actions and the arrow keys.
     */
    fun shift(index: Int, dx: Int, dy: Int, fine: Boolean = false) {
        val at = corners[index and 3]
        val step = max(photoWidth, photoHeight).toDouble() / (if (fine) 500 else 100)
        selected = index and 3
        corners = PageFinder.movedCorner(corners, index and 3, Pt(at.x + dx * step, at.y + dy * step),
            photoWidth, photoHeight)
    }

    /** Makes corner `index` the one the arrow keys move. */
    fun select(index: Int) {
        selected = index and 3
    }

    /**
     * Edge handle `index` (4 to 7) moved one step with a screen reader's swipe up or down: `outward` away
     * from the page's middle, else towards it, a hundredth of the photo's long side along its normal.
     */
    fun nudgeEdge(index: Int, outward: Boolean) {
        val a = corners[index and 3]
        val b = corners[index + 1]
        val normal = normal(a, b) ?: return
        var sumX = 0.0
        var sumY = 0.0
        for (point in corners.corners) {
            sumX += point.x
            sumY += point.y
        }
        val away = normal.x * ((a.x + b.x) / 2 - sumX / 4) + normal.y * ((a.y + b.y) / 2 - sumY / 4)
        val step = max(photoWidth, photoHeight).toDouble() / 100
        val sign = if ((away >= 0) == outward) 1.0 else -1.0
        selected = index
        moveEdge(index, listOf(a, b), sign * step)
    }

    companion object {
        /** How far from a handle's center a touch still takes it. */
        const val HANDLE_HIT_RADIUS = 36.0

        /** The same for the bar in the middle of an edge, which a corner in reach wins over. */
        const val EDGE_HIT_RADIUS = 28.0

        /** The most the photo is zoomed. */
        const val MAX_ZOOM = 5.0

        /** The magnifier's diameter, its zoom over the fitted photo (not the zoomed one), and its gap from the corner. */
        const val LOUPE_SIZE = 120.0
        const val LOUPE_ZOOM = 2.5
        const val LOUPE_GAP = 28.0

        /** The margin around the fitted photo, so a handle on the photo's edge can be reached. */
        const val INSET = 24.0

        private fun zoomed(base: Rect, zoom: Double, pan: ViewSize, size: ViewSize): Rect {
            val middleX = size.width / 2
            val middleY = size.height / 2
            return Rect(middleX + (base.minX - middleX) * zoom + pan.width,
                middleY + (base.minY - middleY) * zoom + pan.height,
                base.width * zoom, base.height * zoom)
        }

        /** The unit normal of the edge from `a` to `b`; null when they meet. */
        private fun normal(a: Pt, b: Pt): Pt? {
            val length = hypot(b.x - a.x, b.y - a.y)
            if (!(length > 0)) return null
            return Pt(-(b.y - a.y) / length, (b.x - a.x) / length)
        }

        /** The magnifier's center for `corner` of a page whose middle is `middle`, in a view of `size`. */
        fun loupeCenter(corner: Pt, middle: Pt, size: ViewSize): Pt {
            val dx = if (corner.x >= middle.x) 1.0 else -1.0
            val dy = if (corner.y >= middle.y) 1.0 else -1.0
            val reach = LOUPE_SIZE / 2 + LOUPE_GAP
            val signsX = doubleArrayOf(dx, -dx, dx, -dx)
            val signsY = doubleArrayOf(dy, dy, -dy, -dy)
            val half = LOUPE_SIZE / 2
            var last = Pt(0.0, 0.0)
            for (index in 0 until 4) {
                val candidate = Pt(corner.x + signsX[index] * reach, corner.y + signsY[index] * reach)
                val fitsX = candidate.x - half >= 0 && candidate.x + half <= size.width
                val fitsY = candidate.y - half >= 0 && candidate.y + half <= size.height
                if (fitsX && fitsY) return candidate
                last = candidate
            }
            return last
        }
    }
}
