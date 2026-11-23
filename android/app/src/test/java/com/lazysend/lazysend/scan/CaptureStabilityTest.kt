package com.lazysend.lazysend.scan

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos
import kotlin.math.sin

private const val FRAME_WIDTH = 1000
private const val FRAME_HEIGHT = 750 // diagonal 1250: 1 % = 12.5 px
private const val FRAME_MS = 33.0

private val page = Quad(Pt(200.0, 100.0), Pt(780.0, 130.0), Pt(800.0, 650.0), Pt(180.0, 640.0))

private fun shifted(q: Quad, dx: Double, dy: Double) =
    Quad(Pt(q.topLeft.x + dx, q.topLeft.y + dy), Pt(q.topRight.x + dx, q.topRight.y + dy),
        Pt(q.bottomRight.x + dx, q.bottomRight.y + dy), Pt(q.bottomLeft.x + dx, q.bottomLeft.y + dy))

private class Step(val quad: Quad?, val confidence: Double)

/** Feeds frames from `start` on, with these readings; returns the indices of frames that fired. */
private fun feed(stability: CaptureStability, start: Int, frames: List<Step>,
                 log: MutableList<CaptureDecision> = ArrayList(),
                 sharpness: Double? = null, brightness: Double? = null): List<Int> {
    val fired = ArrayList<Int>()
    frames.forEachIndexed { n, step ->
        val i = start + n
        val decision = stability.update(CaptureObservation(step.quad, step.confidence, i * FRAME_MS,
            FRAME_WIDTH, FRAME_HEIGHT, sharpness, brightness))
        log.add(decision)
        if (decision.shouldCapture) fired.add(i)
    }
    return fired
}

/** The page held with a tremor of +-1 px (0.1 % of the diagonal), `count` frames. */
private fun held(q: Quad, count: Int, confidence: Double = 0.9): List<Step> = (0 until count).map { i ->
    val dx = if (i % 2 == 0) 1.0 else -1.0
    val dy = (i % 3 - 1).toDouble()
    Step(shifted(q, dx, dy), confidence)
}

private fun missing(count: Int): List<Step> = List(count) { Step(null, 0.0) }

class CaptureStabilityTest {
    @Test
    fun firesOnceWhenThePageHoldsStillLongEnough() {
        val stability = CaptureStability()
        val log = ArrayList<CaptureDecision>()
        val fired = feed(stability, 0, held(page, 60), log)
        // Steadying starts on frame 1 (33 ms); 600 ms later is frame 20 (660 ms).
        assertEquals(listOf(20), fired)
        assertEquals(CaptureState.Captured, stability.state)
        assertEquals(CaptureState.Moving, log[0].state)
        assertEquals(CaptureState.Steadying, log[1].state)
        assertTrue("progress ${log[10].progress}", log[10].progress > 0.45 && log[10].progress < 0.6)
        for (i in 2 until 20) assertTrue(log[i].progress >= log[i - 1].progress)
    }

    @Test
    fun neverFiresWhileThePageMoves() {
        val stability = CaptureStability()
        // 20 px per frame (1.6 % of the diagonal) for 3 s.
        val frames = (0 until 90).map { Step(shifted(page, 20.0 * (it % 10), 0.0), 0.9) }
        assertEquals(emptyList<Int>(), feed(stability, 0, frames))
        assertEquals(CaptureState.Moving, stability.state)
    }

    @Test
    fun neverFiresWhenTheDetectionIsUnsure() {
        val stability = CaptureStability()
        assertEquals(emptyList<Int>(), feed(stability, 0, held(page, 60, 0.55)))
        assertEquals(CaptureState.Moving, stability.state)
        assertEquals(emptyList<Int>(), feed(stability, 60, held(page, 60, 0.3)))
        assertEquals(CaptureState.NoPage, stability.state)
    }

    @Test
    fun aConfidenceDipAboveTheStayLevelKeepsSteadying() {
        val stability = CaptureStability()
        assertEquals(listOf(20), feed(stability, 0, held(page, 8) + held(page, 8, 0.5) + held(page, 30)))
    }

    @Test
    fun aConfidenceDropBelowTheStayLevelStartsOver() {
        val stability = CaptureStability()
        // Frame 8 drops out of steadying; frame 9 holds still against it: steady from 9, fires at frame 28.
        assertEquals(listOf(28), feed(stability, 0, held(page, 8) + held(page, 1, 0.4) + held(page, 40)))
    }

    @Test
    fun smallDriftIsToleratedButAJumpStartsOver() {
        val drift = CaptureStability()
        // Drifting 1 px per frame: after 20 frames the page is 20 px (1.6 %) from where it was, within the 2.5 % to stay.
        val slow = (0 until 40).map { Step(shifted(page, it.toDouble(), 0.0), 0.9) }
        assertEquals(listOf(20), feed(drift, 0, slow))

        val jump = CaptureStability()
        // A jump of 35 px (2.8 %) from where holding started on frame 10 starts over: steady from 11, fires at frame 30.
        assertEquals(listOf(30), feed(jump, 0, held(page, 10) + held(shifted(page, 35.0, 0.0), 40)))
    }

    @Test
    fun aShortDropoutIsBridgedAndALongOneStartsOver() {
        val bridged = CaptureStability()
        // Five frames missing (165 ms) are waited for, but the time from frame 7 to 13 does not
        // count: steady from 1 to 7 (198 ms) and from 13 on, 600 ms are reached at frame 26.
        assertEquals(listOf(26), feed(bridged, 0, held(page, 8) + missing(5) + held(page, 30)))

        val lost = CaptureStability()
        // Ten frames missing (330 ms): the page is new again from frame 18; steady from 19, fires at 38.
        assertEquals(listOf(38), feed(lost, 0, held(page, 8) + missing(10) + held(page, 40)))
    }

    @Test
    fun theTimeThePageIsMissingDoesNotCountAsHoldingStill() {
        val stability = CaptureStability()
        val log = ArrayList<CaptureDecision>()
        // Steady from frame 1 (33 ms), last seen at frame 13 (429 ms), a hand over it until frame 20
        // (660 ms, 231 ms later): 396 ms were held still, 204 more are needed after it comes back.
        assertEquals(listOf(27), feed(stability, 0, held(page, 14) + missing(6) + held(page, 30), log))
        for (i in 14 until 20) {
            assertEquals(CaptureState.Steadying, log[i].state)
            assertEquals(log[13].progress, log[i].progress, 0.0)
        }
        assertTrue(log[20].progress <= log[13].progress)
    }

    @Test
    fun thePageIsTheSameWhicheverCornerItsQuadNamesFirst() {
        // The same outline named from its top edge and from its right edge, frame by frame.
        val renamed = Quad(page.topRight, page.bottomRight, page.bottomLeft, page.topLeft)
        assertTrue(page.maxCornerDistance(renamed) > 500)
        assertEquals(0.0, CaptureStability.movement(page, renamed), 0.0)
        val stability = CaptureStability()
        val frames = held(page, 120).mapIndexed { i, step ->
            val q = step.quad!!
            if (i % 2 == 1) Step(Quad(q.topRight, q.bottomRight, q.bottomLeft, q.topLeft), step.confidence) else step
        }
        assertEquals(listOf(20), feed(stability, 0, frames))
        assertEquals(CaptureState.Captured, stability.state)
    }

    @Test
    fun aSheetTurnedWhereItsCornersAreRenamedIsStillHeldStill() {
        // An A4 sheet (420 x 594 px) turned 54.6 and 54.8 degrees: on either side of the angle where its
        // two upper edges' midpoints are equally high, so fromCorners starts from different corners.
        fun turned(degrees: Double): Quad {
            val angle = degrees * Math.PI / 180
            val c = cos(angle)
            val s = sin(angle)
            val us = doubleArrayOf(-210.0, 210.0, 210.0, -210.0)
            val vs = doubleArrayOf(-297.0, -297.0, 297.0, 297.0)
            return Quad.fromCorners((0 until 4).map { k ->
                Pt(500 + us[k] * c - vs[k] * s, 375 + us[k] * s + vs[k] * c)
            })
        }
        val a = turned(54.6)
        val b = turned(54.8)
        assertTrue("the names did not change: $a $b", a.maxCornerDistance(b) > 200)
        assertTrue(CaptureStability.movement(a, b) < 3)
        val stability = CaptureStability()
        val frames = (0 until 61).map { Step(if (it % 2 == 0) a else b, 0.9) }
        assertEquals(listOf(20), feed(stability, 0, frames))
    }

    @Test
    fun aPauseBetweenFramesDoesNotTakeTheSamePageAgain() {
        // A 300 ms pause in the frames right after the shutter fired (the photo being taken), the page
        // still there: it stays taken. Laid 200 px aside afterwards, the next page is taken.
        val stability = CaptureStability()
        val fired = ArrayList<Int>()
        val frames = held(page, 61) + held(shifted(page, 200.0, 0.0), 40)
        frames.forEachIndexed { i, step ->
            val t = i * FRAME_MS + (if (i > 20) 300 else 0)
            val decision = stability.update(CaptureObservation(step.quad, step.confidence, t, FRAME_WIDTH, FRAME_HEIGHT))
            if (decision.shouldCapture) fired.add(i)
        }
        assertEquals(listOf(20, 81), fired)
    }

    @Test
    fun theSamePageIsNotTakenTwice() {
        val stability = CaptureStability()
        assertEquals(listOf(20), feed(stability, 0, held(page, 120)))
        assertEquals(CaptureState.Captured, stability.state)
    }

    @Test
    fun theNextPageIsTakenAfterThePageLeavesOrMoves() {
        val removed = CaptureStability()
        // Captured at 20; gone from 30 to 39; back at 40, steady from 41, fires at 60.
        assertEquals(listOf(20, 60), feed(removed, 0, held(page, 30) + missing(10) + held(page, 40)))

        val moved = CaptureStability()
        // The next page laid 200 px (16 %) aside: re-armed at 30, steady from 31, fires at 50.
        assertEquals(listOf(20, 50), feed(moved, 0, held(page, 30) + held(shifted(page, 200.0, 0.0), 40)))
    }

    @Test
    fun resetArmsTheShutterAgain() {
        val stability = CaptureStability()
        assertEquals(listOf(20), feed(stability, 0, held(page, 30)))
        stability.reset()
        assertEquals(CaptureState.NoPage, stability.state)
        // After a reset the next frame is a page seen again: steady from 31, fires at 50.
        assertEquals(listOf(50), feed(stability, 30, held(page, 30)))
    }

    @Test
    fun aHeldPageWaitsForASharpFrame() {
        val stability = CaptureStability()
        val log = ArrayList<CaptureDecision>()
        // Blurred (the camera still focusing) for 40 frames: held still long enough from frame 20, never taken.
        assertEquals(emptyList<Int>(), feed(stability, 0, held(page, 40), log, sharpness = 10.0, brightness = 180.0))
        for (i in 20 until 40) {
            assertEquals(CaptureState.Steadying, log[i].state)
            assertEquals(1.0, log[i].progress, 0.0)
            assertEquals(CaptureQuality.Blurry, log[i].quality)
        }
        // The first sharp frame is taken, and only once.
        assertEquals(listOf(40), feed(stability, 40, held(page, 30), log, sharpness = 400.0, brightness = 180.0))
        assertEquals(CaptureQuality.Good, log[40].quality)
        assertEquals(CaptureState.Captured, stability.state)
    }

    @Test
    fun aHeldPageWaitsForLight() {
        val stability = CaptureStability()
        val log = ArrayList<CaptureDecision>()
        assertEquals(emptyList<Int>(), feed(stability, 0, held(page, 30), log, sharpness = 400.0, brightness = 20.0))
        assertEquals(CaptureQuality.Dark, log[29].quality)
        assertEquals(CaptureState.Steadying, log[29].state)
        assertEquals(listOf(30), feed(stability, 30, held(page, 10), log, sharpness = 400.0, brightness = 120.0))
        // Moving frames are judged too, so the screen can say why before the page holds still.
        val moving = CaptureStability()
        val decision = moving.update(CaptureObservation(page, 0.9, 0.0, FRAME_WIDTH, FRAME_HEIGHT, 400.0, 20.0))
        assertEquals(CaptureQuality.Dark, decision.quality)
        assertEquals(CaptureState.Moving, decision.state)
    }

    @Test
    fun aSteadyBlurredPageSuggestsTheShutterAfterTwoSeconds() {
        val stability = CaptureStability()
        val log = ArrayList<CaptureDecision>()
        assertEquals(emptyList<Int>(), feed(stability, 0, held(page, 100), log, sharpness = 10.0, brightness = 180.0))
        // Blocked from frame 20 (660 ms); 2 s later is frame 81 (2673 ms).
        for (i in 20 until 81) assertFalse("frame $i", log[i].suggestsShutter)
        for (i in 81 until 100) assertTrue("frame $i", log[i].suggestsShutter)
        // Darkness is another wait: no suggestion, and the time starts over.
        assertEquals(emptyList<Int>(), feed(stability, 100, held(page, 5), log, sharpness = 400.0, brightness = 20.0))
        assertFalse(log[104].suggestsShutter)
        assertEquals(emptyList<Int>(), feed(stability, 105, held(page, 5), log, sharpness = 10.0, brightness = 180.0))
        assertFalse(log[109].suggestsShutter)
        // The first sharp frame is taken as before.
        assertEquals(listOf(110), feed(stability, 110, held(page, 5), log, sharpness = 400.0, brightness = 180.0))
        assertFalse(log[110].suggestsShutter)
    }

    @Test
    fun thePlacementNamesAFarOrCutOffPage() {
        assertEquals(CapturePlacement.Fine, CaptureStability.placement(page, FRAME_WIDTH, FRAME_HEIGHT))
        val small = Quad(Pt(350.0, 275.0), Pt(650.0, 275.0), Pt(650.0, 475.0), Pt(350.0, 475.0))
        assertEquals(CapturePlacement.Far, CaptureStability.placement(small, FRAME_WIDTH, FRAME_HEIGHT))
        // 12.5 px is 1 % of the diagonal: a corner at 10 px is on the edge, one at 20 px is not.
        assertEquals(CapturePlacement.CutOff, CaptureStability.placement(shifted(page, -170.0, 0.0), FRAME_WIDTH, FRAME_HEIGHT))
        assertEquals(CapturePlacement.Fine, CaptureStability.placement(shifted(page, -160.0, 0.0), FRAME_WIDTH, FRAME_HEIGHT))
        assertEquals(CapturePlacement.CutOff, CaptureStability.placement(shifted(page, 0.0, 100.0), FRAME_WIDTH, FRAME_HEIGHT))
    }

    @Test
    fun theReadingsAreJudgedDarkFirst() {
        assertEquals(40.0, CaptureStability.MIN_SHARPNESS, 0.0)
        assertEquals(50.0, CaptureStability.MIN_BRIGHTNESS, 0.0)
        assertEquals(CaptureQuality.Dark, CaptureStability.judge(10.0, 20.0))
        assertEquals(CaptureQuality.Blurry, CaptureStability.judge(10.0, 120.0))
        assertEquals(CaptureQuality.Good, CaptureStability.judge(40.0, 50.0))
        assertEquals(CaptureQuality.Blurry, CaptureStability.judge(39.99, 50.0))
        assertEquals(CaptureQuality.Dark, CaptureStability.judge(400.0, 49.99))
        assertEquals(CaptureQuality.Good, CaptureStability.judge(null, null))
        assertEquals(CaptureQuality.Good, CaptureStability.judge(null, 120.0))
        val strict = CaptureStabilityOptions(minSharpness = 500.0, minBrightness = 10.0)
        assertEquals(CaptureQuality.Blurry, CaptureStability.judge(400.0, 20.0, strict))
        // Frames without readings are taken as before.
        assertEquals(listOf(20), feed(CaptureStability(), 0, held(page, 30)))
    }

    @Test
    fun aPhotoTakenByHandCountsAsTaken() {
        val stability = CaptureStability()
        // Nothing seen yet: nothing to mark.
        stability.markCaptured()
        assertEquals(CaptureState.NoPage, stability.state)
        // Held still for ten frames, then the shutter pressed by hand: the same page is not taken again...
        assertEquals(emptyList<Int>(), feed(stability, 0, held(page, 10)))
        stability.markCaptured()
        assertEquals(CaptureState.Captured, stability.state)
        assertEquals(emptyList<Int>(), feed(stability, 10, held(page, 60)))
        // ...the next page laid 200 px aside is: re-armed at 70, steady from 71, fires at 90.
        assertEquals(listOf(90), feed(stability, 70, held(shifted(page, 200.0, 0.0), 40)))
    }

    @Test
    fun aPauseIsNeitherTimeMissingNorTimeHeldStill() {
        // Taken at frame 20; the camera stops (the corner editor) after frame 29 and starts again at frame 200.
        val stability = CaptureStability()
        assertEquals(listOf(20), feed(stability, 0, held(page, 30)))
        stability.resume(200 * FRAME_MS)
        // The first frame back misses the page (the exposure still settling): the page taken stays taken...
        val log = ArrayList<CaptureDecision>()
        assertEquals(emptyList<Int>(), feed(stability, 200, missing(1), log))
        assertEquals(CaptureState.Captured, log[0].state)
        // ...and the same page held still again is not taken again.
        assertEquals(emptyList<Int>(), feed(stability, 201, held(page, 60)))
        assertEquals(CaptureState.Captured, stability.state)

        // Without resume the pause counts as the page gone, and the same page is taken twice.
        val unresumed = CaptureStability()
        assertEquals(listOf(20), feed(unresumed, 0, held(page, 30)))
        val unresumedLog = ArrayList<CaptureDecision>()
        assertEquals(emptyList<Int>(), feed(unresumed, 200, missing(1), unresumedLog))
        assertEquals(CaptureState.NoPage, unresumedLog[0].state)
        assertEquals(listOf(221), feed(unresumed, 201, held(page, 60)))

        // A page that went meanwhile is gone once frames without it span maxGapMs, as ever.
        val gone = CaptureStability()
        assertEquals(listOf(20), feed(gone, 0, held(page, 30)))
        gone.resume(200 * FRAME_MS)
        val goneLog = ArrayList<CaptureDecision>()
        assertEquals(emptyList<Int>(), feed(gone, 200, missing(9), goneLog))
        assertEquals(CaptureState.Captured, goneLog[7].state)
        assertEquals(CaptureState.NoPage, goneLog[8].state)

        // A page holding still when the camera stopped goes on from where it was: steady from 1, 264 ms held
        // by frame 9, so 600 ms are reached at frame 311, not at once.
        val steady = CaptureStability()
        assertEquals(emptyList<Int>(), feed(steady, 0, held(page, 10)))
        steady.resume(300 * FRAME_MS)
        assertEquals(listOf(311), feed(steady, 300, held(page, 20)))

        // Nothing to resume before any frame.
        val fresh = CaptureStability()
        fresh.resume(1000.0)
        assertEquals(listOf(20), feed(fresh, 0, held(page, 30)))
    }
}
