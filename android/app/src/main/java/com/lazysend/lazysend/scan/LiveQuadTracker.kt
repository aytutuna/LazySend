package com.lazysend.lazysend.scan

import kotlin.math.max
import kotlin.math.sqrt

/**
 * One live frame of the camera, made small for the page search: its pixels as the sensor gives them (not
 * turned for the screen), when it was taken in milliseconds of the capture clock, and the page the corner
 * model found in it (`PageFinder.frameCandidate`, in `image`'s pixels), null when it found none or did not run.
 */
class ScanFrame(val image: RgbaImage, val timestampMs: Double, val page: QuadCandidate? = null)

/**
 * What the tracker saw in a frame: the page's outline (corners as shares of the frame, 0..1, named by
 * `Quad.fromCorners`), null when no page is in view; how steady it is; whether it holds still now; the
 * frame's time; and the shutter's decision: take the photo now (`shouldCapture`, once per page held still
 * on a sharp, lit frame), how the frame was judged (`quality`), how the page sits in the frame (`placement`)
 * and whether a blurred page has waited long enough to suggest the shutter (`suggestsShutter`).
 * `isSteady` is for the outline's colour only: true while `Steadying`, or `Captured` while the page stays
 * where it held still; the automatic shutter follows `shouldCapture`.
 */
data class LiveQuadUpdate(
    val outline: Quad?,
    val state: CaptureState,
    val progress: Double,
    val timestampMs: Double,
    val isSteady: Boolean = state == CaptureState.Steadying,
    val shouldCapture: Boolean = false,
    val quality: CaptureQuality = CaptureQuality.Good,
    val placement: CapturePlacement = CapturePlacement.Fine,
    val suggestsShutter: Boolean = false,
)

/**
 * Follows the page in the camera's live frames for the outline drawn over the preview. About ten frames a
 * second are looked at (`MIN_FRAME_GAP_MS`; the others are passed over before any work): the page the
 * corner model found in the frame when it is a page's (`PageFinder.accepted`) and sure enough to start
 * holding still (`CaptureStability.ENTER_CONFIDENCE`, at least). What is found is steadied
 * (`LiveQuadFilter`), and how steady the steadied page is comes from `CaptureStability`. Once it has taken
 * the page (`Captured`) it keeps that state until the page moves `newPageMovement` away, so whether the
 * page holds still meanwhile is judged here, by the same rules. Each frame is also measured
 * (`FrameQuality`, over the page found), so the shutter's decision comes only from a page held still on a
 * sharp, lit frame. A photo taken (`markCaptured()`) counts the page in view as taken; a pause (`pause()`:
 * the camera stopped for the corner editor, the background) keeps that, and the time the camera was stopped
 * counts neither as time the page was missing nor as time it held still. A page held still again after it
 * went or was covered is not decided on when it looks like the page last photographed (`PageThumbnail`).
 * Frames are handled one at a time on the caller's thread; `reset()` may be called from any thread and
 * drops a frame being handled meanwhile.
 */
class LiveQuadTracker(
    private val stabilityOptions: CaptureStabilityOptions = CaptureStabilityOptions(),
    quality: QualityMeasure? = null,
) {
    private val measure: QualityMeasure = quality ?: { image, page -> FrameQuality.measure(image, page) }
    private val lock = Any()
    private var stability = CaptureStability(stabilityOptions)
    private var lastHandledMs: Double? = null
    private var filter = LiveQuadFilter()
    private var lastFound: Quad? = null

    /** Where the page held still while `Captured` (pixels); null while it does not. */
    private var heldAt: Quad? = null
    private var frameWidth = 0
    private var frameHeight = 0
    private var generation = 0

    /** The first frame after a pause resumes `stability` first. */
    private var resuming = false

    /** A photo was taken of the page `stability` counts as taken (`markCaptured()`), not only decided on. */
    private var photographed = false
    private var latestImage: RgbaImage? = null
    private var photographedLook: PageThumbnail? = null

    /** Handles `frame` unless it comes too soon after the last one (null then). A frame from an earlier time than the last one or of another size starts over. */
    fun process(frame: ScanFrame): LiveQuadUpdate? {
        val t = frame.timestampMs
        val width = frame.image.width
        val height = frame.image.height
        val started = synchronized(lock) {
            val last = lastHandledMs
            if (last != null) {
                if (t < last) {
                    clearState()
                } else if (t - last < MIN_FRAME_GAP_MS) {
                    return null
                }
            }
            if (width != frameWidth || height != frameHeight) {
                clearState()
                frameWidth = width
                frameHeight = height
            }
            lastHandledMs = t
            generation
        }

        // A page the model is less sure of than holding still needs would never be taken.
        val floor = max(PageFinder.MIN_MODEL_CONFIDENCE, stabilityOptions.enterConfidence)
        var found: Quad? = null
        var confidence = 0.0
        val page = frame.page
        if (page != null && page.confidence >= floor) {
            val quad = PageFinder.accepted(page, width, height)
            if (quad != null) {
                found = quad
                confidence = page.confidence
            }
        }
        val reading = measure(frame.image, found)

        synchronized(lock) {
            // Reset while the frame was handled: its answer belongs to before.
            if (started != generation) return null
            if (resuming) {
                resuming = false
                stability.resume(t)
            }
            val diagonal = sqrt(width.toDouble() * width.toDouble() + height.toDouble() * height.toDouble())
            val steadied = filter.update(found, t, diagonal)
            val observation = CaptureObservation(steadied.page, confidence, t, width, height,
                reading.sharpness, reading.brightness)
            var decision = stability.update(observation)
            latestImage = frame.image
            // The page came back after a shake or a hand over it and held still: it is the page already taken.
            val look = photographedLook
            val steadiedPage = steadied.page
            if (decision.shouldCapture && look != null && steadiedPage != null &&
                PageThumbnail(frame.image, steadiedPage).matches(look)) {
                decision = decision.copy(shouldCapture = false)
                photographed = true
            }
            if (decision.state != CaptureState.Captured) photographed = false
            val steady = holdsStill(decision, steadiedPage, confidence, diagonal)
            lastFound = steadiedPage
            val shown = steadied.shown
            val outline = if (shown != null) normalized(shown, width, height) else null
            val placement = if (steadiedPage != null) {
                CaptureStability.placement(steadiedPage, width, height)
            } else {
                CapturePlacement.Fine
            }
            return LiveQuadUpdate(outline, decision.state, decision.progress, t, steady, decision.shouldCapture,
                decision.quality, placement, decision.suggestsShutter)
        }
    }

    /**
     * Whether the page holds still after `decision` (called with the lock held): while `Steadying`, yes;
     * while `Captured`, as long as no corner strays `stayMovement` of the `diagonal` from where it held
     * still, and again once no corner moved `enterMovement` since the frame before (with the confidences
     * `CaptureStability` asks for); a page missed for a moment holds still as it did. Otherwise, no.
     */
    private fun holdsStill(decision: CaptureDecision, quad: Quad?, confidence: Double, diagonal: Double): Boolean {
        val o = stabilityOptions
        when (decision.state) {
            CaptureState.Steadying -> {
                heldAt = null
                return true
            }
            CaptureState.NoPage, CaptureState.Moving -> {
                heldAt = null
                return false
            }
            CaptureState.Captured -> {
                val found = quad ?: return heldAt != null
                if (decision.shouldCapture) {
                    heldAt = found
                    return true
                }
                val held = heldAt
                if (held != null && confidence >= o.stayConfidence &&
                    CaptureStability.movement(found, held) <= o.stayMovement * diagonal) {
                    return true
                }
                val earlier = lastFound
                if (earlier != null && confidence >= o.enterConfidence &&
                    CaptureStability.movement(found, earlier) <= o.enterMovement * diagonal) {
                    heldAt = earlier
                    return true
                }
                heldAt = null
                return false
            }
        }
    }

    /**
     * Judges the page afresh: how steady it is and whether it was taken start over with the next frame. The
     * outline drawn stays, so it does not blink; once frames stop coming for longer than `HOLD_MS` it goes
     * by itself.
     */
    fun reset() {
        synchronized(lock) {
            clearJudgement()
            generation++
        }
    }

    /**
     * A photo was taken of the page in view (by hand, or as the shutter's decision said): it counts as
     * taken, so it is not taken again until it moves away or goes.
     */
    fun markCaptured() {
        synchronized(lock) {
            stability.markCaptured()
            if (stability.state == CaptureState.Captured) {
                heldAt = lastFound
                photographed = true
                photographedLook = null
                val image = latestImage
                val page = lastFound
                if (image != null && page != null) photographedLook = PageThumbnail(image, page)
            }
        }
    }

    /**
     * The automatic shutter was turned on, or a photo can be taken again: a page `CaptureStability` counted
     * as taken while no photo was taken of it is judged afresh, so it is taken once it holds still; a page
     * photographed stays taken, and nothing else changes.
     */
    fun rearm() {
        val untaken = synchronized(lock) { stability.state == CaptureState.Captured && !photographed }
        if (untaken) reset()
    }

    /**
     * The camera stops for a while (the corner editor, the background): what is known of the page is kept,
     * above all that it was taken, and the time until the next frame counts neither as time the page was
     * missing nor as time it held still.
     */
    fun pause() {
        synchronized(lock) { resuming = true }
    }

    /** Forgets everything (frames of another size, a clock that started over). Called with the lock held. */
    private fun clearState() {
        clearJudgement()
        filter = LiveQuadFilter()
    }

    /** Forgets how steady the page was and whether it was taken. Called with the lock held. */
    private fun clearJudgement() {
        stability = CaptureStability(stabilityOptions)
        lastHandledMs = null
        lastFound = null
        heldAt = null
        resuming = false
        photographed = false
        photographedLook = null
    }

    companion object {
        /** A frame this soon after the last one handled is passed over (a 30 fps camera's every third frame is used). */
        const val MIN_FRAME_GAP_MS = 90.0

        /** The same while the phone is warm, which the frame feed uses to pass frames over: about four a second. */
        const val WARM_FRAME_GAP_MS = 225.0

        /** The long side live frames are searched at. */
        const val ANALYSIS_LONG_SIDE = 480

        /** A page missed for at most this long keeps its outline. */
        const val HOLD_MS = 300.0

        /** `quad` (pixels of a `width` x `height` frame) as shares of the frame. */
        fun normalized(quad: Quad, width: Int, height: Int): Quad =
            quad.scaled(1.0 / max(width, 1).toDouble(), 1.0 / max(height, 1).toDouble())

        /**
         * A live outline (shares of the sensor's frame, as the frames come) in the photo taken with the turn
         * `rotationDegrees` (clockwise; 0, 90, 180 or 270), as shares of that photo once it is upright; null
         * for any other turn.
         */
        fun photoOutline(outline: Quad, rotationDegrees: Int): Quad? {
            val turn = ((rotationDegrees % 360) + 360) % 360
            if (turn % 90 != 0) return null
            val points = outline.corners.map { corner ->
                val x = corner.x
                val y = corner.y
                when (turn / 90) {
                    1 -> Pt(1.0 - y, x)
                    2 -> Pt(1.0 - x, 1.0 - y)
                    3 -> Pt(y, 1.0 - x)
                    else -> Pt(x, y)
                }
            }
            return Quad.fromCorners(points)
        }
    }
}

typealias QualityMeasure = (RgbaImage, Quad?) -> FrameQualityReading
