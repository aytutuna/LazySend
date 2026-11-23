package com.lazysend.lazysend.scan

import kotlin.math.max
import kotlin.math.min

/**
 * Where the page is in a photo: the corners in the photo's pixels, within the photo, and whether the model
 * was sure, the photo's edges back its outline and the page can be corrected. When `clear` is false the
 * corner editor starts from `corners`.
 */
data class PageFound(val corners: Quad, val clear: Boolean)

/** Finds the page in a photo or a live frame with the corner model, and keeps the corners the editor moves usable. */
object PageFinder {
    /** A page found with at least this confidence, and backed by the photo's edges, is cut out without asking. */
    const val SURE_CONFIDENCE = 0.7

    /** The model's page is taken from this confidence up (its weakest corner's peak). */
    const val MIN_MODEL_CONFIDENCE = 0.5

    /** The share of the weakest side the photo's edges must back (`QuadRefinement.support`) for a clear find. */
    const val MIN_SURE_SUPPORT = 0.7

    /** With nothing found, the editor starts with a rectangle this share of the photo in from each edge. */
    const val START_INSET = 0.1

    /** Every edge of the corners is at least this many photo pixels long. */
    const val MIN_EDGE_PIXELS = 16.0

    /** A page covers at least this share of the frame... */
    private const val MIN_AREA_SHARE = 0.1

    /** ...and is at most this many times as long as wide. */
    private const val MAX_LONG_OVER_SHORT = 2.0

    /**
     * The page in `photo` (upright). A page the model is sure of is moved onto the photo's edges; anything
     * less gives the corner editor's start, a rectangle inset from the edges when the model found nothing.
     */
    fun find(photo: RgbaImage, model: CornerModel?): PageFound {
        val w = photo.width
        val h = photo.height
        val start = PageFound(startCorners(w, h), false)
        val heat = model?.heatmaps(CornerModelInput.make(photo)) ?: return start
        val seen = CornerHeatmap.decode(heat.values, heat.width, heat.height) ?: return start
        if (seen.confidence < MIN_MODEL_CONFIDENCE) return start
        val candidate = QuadCandidate(seen.quad.scaled(w.toDouble(), h.toDouble()), seen.confidence)
        val outline = documentOutline(candidate, w, h)
        if (outline == null || !canUseCorners(outline)) return start
        val refinement = QuadRefiner.refine(photo, outline)
        val corners = clamped(refinement.quad, w, h)
        val clear = seen.confidence >= SURE_CONFIDENCE && refinement.support >= MIN_SURE_SUPPORT &&
            PerspectiveCorrector.plan(corners, w, h) != null
        return PageFound(corners, clear)
    }

    /** The model's page for a live frame of `width` x `height`, when it is sure enough and has a page's shape. */
    fun accepted(candidate: QuadCandidate, width: Int, height: Int): Quad? {
        if (candidate.confidence < MIN_MODEL_CONFIDENCE) return null
        val outline = documentOutline(candidate, width, height) ?: return null
        val inside = clamped(outline, width, height)
        return if (canUseCorners(inside)) inside else null
    }

    /**
     * The model's page in a live `frame` as the sensor gives it, turned upright by `turn` degrees (a
     * multiple of 90) for the model, which was trained on pages the right way up, and back into the frame's
     * own pixels. Null when the model found no page.
     */
    fun frameCandidate(frame: RgbaImage, turn: Int, model: CornerModel): QuadCandidate? {
        val upright = frame.rotatedQuarterTurns(turn / 90)
        val heat = model.heatmaps(CornerModelInput.make(upright)) ?: return null
        val seen = CornerHeatmap.decode(heat.values, heat.width, heat.height) ?: return null
        val back = LiveQuadTracker.photoOutline(seen.quad, (360 - turn) % 360) ?: return null
        return QuadCandidate(back.scaled(frame.width.toDouble(), frame.height.toDouble()), seen.confidence)
    }

    /** The candidate named by `Quad.fromCorners` when it is convex and a page's size and shape. */
    internal fun documentOutline(candidate: QuadCandidate, width: Int, height: Int): Quad? {
        if (width <= 0 || height <= 0) return null
        val quad = Quad.fromCorners(candidate.quad.corners)
        if (!quad.isConvex) return null
        val share = quad.area / (width.toDouble() * height.toDouble())
        if (share < MIN_AREA_SHARE || share > 1) return null
        val shape = PerspectiveCorrector.estimateAspect(quad, width.toDouble(), height.toDouble()).longOverShort
        return if (shape >= 1 && shape <= MAX_LONG_OVER_SHORT) quad else null
    }

    /** The corners of the whole photo. */
    fun wholePhoto(width: Int, height: Int): Quad {
        val w = width.toDouble()
        val h = height.toDouble()
        return Quad(Pt(0.0, 0.0), Pt(w, 0.0), Pt(w, h), Pt(0.0, h))
    }

    /** A rectangle `START_INSET` of the photo in from each edge. */
    fun startCorners(width: Int, height: Int): Quad {
        val w = width.toDouble()
        val h = height.toDouble()
        val dx = w * START_INSET
        val dy = h * START_INSET
        return Quad(Pt(dx, dy), Pt(w - dx, dy), Pt(w - dx, h - dy), Pt(dx, h - dy))
    }

    /** `quad` with every corner moved into the photo; `startCorners` when that leaves no usable outline. */
    fun clamped(quad: Quad, width: Int, height: Int): Quad {
        val c = quad.corners.map { clamp(it, width.toDouble(), height.toDouble()) }
        val inside = Quad(c[0], c[1], c[2], c[3])
        return if (canUseCorners(inside)) inside else startCorners(width, height)
    }

    /** Corners a page can be cut out along: a convex outline, every edge at least `MIN_EDGE_PIXELS` long. */
    fun canUseCorners(quad: Quad): Boolean {
        if (!quad.isConvex) return false
        for (i in 0 until 4) {
            if (!(quad.edgeLength(i) >= MIN_EDGE_PIXELS)) return false
        }
        return true
    }

    /**
     * `quad` with corner `index` (0 top left, then clockwise) moved to `to`, kept within the photo; the quad
     * as it was when the move would leave corners the page cannot be cut out along.
     */
    fun movedCorner(quad: Quad, index: Int, to: Pt, width: Int, height: Int): Quad {
        val corners = quad.corners.toMutableList()
        corners[index and 3] = clamp(to, width.toDouble(), height.toDouble())
        val moved = Quad(corners[0], corners[1], corners[2], corners[3])
        return if (canUseCorners(moved)) moved else quad
    }

    private fun clamp(p: Pt, width: Double, height: Double): Pt = Pt(min(max(p.x, 0.0), width), min(max(p.y, 0.0), height))
}
