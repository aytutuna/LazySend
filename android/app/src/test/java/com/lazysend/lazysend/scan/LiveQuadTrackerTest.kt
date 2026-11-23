package com.lazysend.lazysend.scan

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

private val goodReadings: QualityMeasure = { _, _ -> FrameQualityReading(1000.0, 200.0) }

/** A frame at `index` (100 ms apart) in which the model finds the sheet `dx` px to the right, surely. */
private fun sheetFrame(image: RgbaImage, index: Int, dx: Double, from: Double = 0.0) =
    ScanFrame(image, from + index * 100.0, QuadCandidate(LiveFrames.sheetMoved(dx), 1.0))

/** A frame of `width` x `height` of one grey, with the model's `page` if any. */
private fun plainFrame(t: Double, width: Int = 64, height: Int = 48, page: QuadCandidate? = null) =
    ScanFrame(RgbaImage.filled(width, height, 90, 90, 90), t, page)

/** A page outline in a 64 x 48 frame. */
private val stubQuad = Quad(Pt(10.0, 8.0), Pt(50.0, 8.0), Pt(50.0, 40.0), Pt(10.0, 40.0))

private fun assertQuad(actual: Quad?, expected: Quad, accuracy: Double) {
    assertNotNull("No outline", actual)
    for (index in 0 until 4) {
        assertEquals(expected[index].x, actual!![index].x, accuracy)
        assertEquals(expected[index].y, actual[index].y, accuracy)
    }
}

class LiveQuadTrackerTest {
    @Test
    fun theShutterFiresOnlyForAPageHeldStillOnASharpLitFrame() {
        // The sheet held still (+-1 px) at 10 frames a second: blurred while the camera focuses (frames 0-14), then too
        // dark (15-24), then sharp and lit (25-40). Each frame is measured for real, over the page found.
        val blurred = LiveFrames.frame(blur = 2)
        val dark = LiveFrames.frame(dim = 40)
        val sharp = LiveFrames.frame()
        val tracker = LiveQuadTracker()
        val updates = ArrayList<LiveQuadUpdate>()
        for (index in 0 until 41) {
            val image = if (index < 15) blurred else if (index < 25) dark else sharp
            tracker.process(sheetFrame(image, index, if (index % 2 == 0) 1.0 else -1.0))?.let { updates.add(it) }
        }
        assertEquals(41, updates.size)
        val fired = updates.indices.filter { updates[it].shouldCapture }
        // Held still from frame 1, long enough by frame 7: it waits through the blurred and dark frames, and the first
        // sharp, lit frame is taken, once.
        assertEquals(listOf(25), fired)
        assertEquals(CaptureState.Steadying, updates[7].state)
        assertEquals(CaptureQuality.Blurry, updates[7].quality)
        assertEquals(1.0, updates[14].progress, 0.0)
        assertEquals(CaptureQuality.Dark, updates[15].quality)
        assertEquals(CaptureQuality.Good, updates[25].quality)
        assertEquals(CaptureState.Captured, updates[40].state)
        // The outline's colour says nothing of the shutter: green while waiting, never a shot.
        assertTrue(updates[10].isSteady)
        assertFalse(updates[10].shouldCapture)
    }

    @Test
    fun aMovingPageIsNeverTakenHoweverSharp() {
        val tracker = LiveQuadTracker()
        val sharp = LiveFrames.frame()
        for (index in 0 until 40) {
            // 8 px a frame: never within the 4 px to hold still.
            val update = tracker.process(sheetFrame(sharp, index, ((index % 5) * 8).toDouble())) ?: continue
            assertFalse(update.shouldCapture)
            assertTrue(update.state != CaptureState.Steadying)
        }
    }

    @Test
    fun aPhotoTakenCountsThePageAsTakenUntilANewPageComes() {
        val tracker = LiveQuadTracker(quality = goodReadings)
        val sharp = LiveFrames.frame()
        val fired = ArrayList<Int>()
        for (index in 0 until 60) {
            var dx = if (index % 2 == 0) 1.0 else -1.0
            if (index >= 40) dx += 100 // the next page laid 100 px aside
            val update = tracker.process(sheetFrame(sharp, index, dx))
            if (update != null && update.shouldCapture) fired.add(index)
            // Taken by hand while the page holds still, before the shutter would have fired.
            if (index == 3) tracker.markCaptured()
        }
        // Never taken again until the next page came: its jump believed on its second sighting (41), steady from 42,
        // taken at 48.
        assertEquals(listOf(48), fired)
    }

    @Test
    fun aPauseKeepsThePageTakenWhileAResetForgetsIt() {
        val tracker = LiveQuadTracker(quality = goodReadings)
        val sharp = LiveFrames.frame()
        fun run(from: Double): Int {
            var shots = 0
            for (index in 0 until 20) {
                val update = tracker.process(sheetFrame(sharp, index, if (index % 2 == 0) 1.0 else -1.0, from))
                if (update != null && update.shouldCapture) shots++
            }
            return shots
        }
        assertEquals(1, run(0.0))
        // Paused (the corner editor was open) with the same page still in view: not taken again.
        tracker.pause()
        assertEquals(0, run(5000.0))
        // Reset (the screen closed): forgotten, so the page is taken again.
        tracker.reset()
        assertEquals(1, run(10000.0))
    }

    @Test
    fun aFrameTooSoonIsPassedOverAndAClockThatStartsOverStartsAgain() {
        val tracker = LiveQuadTracker()
        assertNotNull(tracker.process(plainFrame(1000.0)))
        assertNull(tracker.process(plainFrame(1033.0)))
        assertNull(tracker.process(plainFrame(1066.0)))
        assertNull(tracker.process(plainFrame(1089.9)))
        assertNotNull(tracker.process(plainFrame(1090.0)))
        // The camera started again: its clock begins anew, and so does the tracker.
        assertNotNull(tracker.process(plainFrame(20.0)))
        assertNull(tracker.process(plainFrame(40.0)))
        // A frame of another size starts over too.
        assertNotNull(tracker.process(plainFrame(200.0, width = 48, height = 64)))
    }

    @Test
    fun theModelsPageIsFollowedWhenSureAndKeptForAMomentWhenMissed() {
        val tracker = LiveQuadTracker(quality = goodReadings)
        val sure = QuadCandidate(stubQuad, 0.9)
        val expected = LiveQuadTracker.normalized(stubQuad, 64, 48)
        // Drawn from the second sighting.
        assertNull(tracker.process(plainFrame(0.0, page = sure))?.outline)
        assertEquals(expected, tracker.process(plainFrame(100.0, page = sure))?.outline)
        // Too unsure, a sliver or nothing: the outline is held for 300 ms after the page was last found, then gone.
        assertEquals(expected, tracker.process(plainFrame(200.0, page = QuadCandidate(stubQuad, 0.3)))?.outline)
        val sliver = Quad(Pt(10.0, 20.0), Pt(54.0, 20.0), Pt(54.0, 24.0), Pt(10.0, 24.0))
        assertEquals(expected, tracker.process(plainFrame(300.0, page = QuadCandidate(sliver, 0.9)))?.outline)
        assertEquals(expected, tracker.process(plainFrame(400.0))?.outline)
        assertNull(tracker.process(plainFrame(500.0))?.outline)
        // Less sure than holding still needs (0.6): never drawn.
        assertNull(tracker.process(plainFrame(600.0, page = QuadCandidate(stubQuad, 0.55)))?.outline)
        assertNull(tracker.process(plainFrame(700.0, page = QuadCandidate(stubQuad, 0.55)))?.outline)
    }

    @Test
    fun aPageTheModelFlickersOnIsOutlinedWithoutShaking() {
        val tracker = LiveQuadTracker(quality = goodReadings)
        val image = LiveFrames.frame()
        val page = QuadCandidate(LiveFrames.sheet, 0.9)
        val outlines = ArrayList<Quad?>()
        for (index in 0 until 20) {
            val seen = if (index < 2 || index % 2 == 1) page else null
            outlines.add(tracker.process(ScanFrame(image, index * 100.0, seen))?.outline)
        }
        val sheet = LiveQuadTracker.normalized(LiveFrames.sheet, 320, 240)
        for (index in 1 until 20) assertEquals("at $index", sheet, outlines[index])
    }

    @Test
    fun aPageUnderAFifthOfTheFrameIsFarAndOneAtTheEdgeIsCutOff() {
        val tracker = LiveQuadTracker(quality = goodReadings)
        val image = LiveFrames.frame()
        val far = Quad(Pt(110.0, 70.0), Pt(210.0, 70.0), Pt(210.0, 170.0), Pt(110.0, 170.0))
        var last: LiveQuadUpdate? = null
        for (index in 0 until 4) last = tracker.process(ScanFrame(image, index * 100.0, QuadCandidate(far, 1.0)))
        assertEquals(CapturePlacement.Far, last?.placement)
        val edge = Quad(Pt(0.0, 10.0), Pt(230.0, 10.0), Pt(230.0, 200.0), Pt(0.0, 200.0))
        val other = LiveQuadTracker(quality = goodReadings)
        for (index in 0 until 4) last = other.process(ScanFrame(image, index * 100.0, QuadCandidate(edge, 1.0)))
        assertEquals(CapturePlacement.CutOff, last?.placement)
    }

    @Test
    fun theFilterDampsJitter() {
        // 320 x 240 (diagonal 400 px): corners tremble +-2 px about the sheet (within the 4 px of jitter).
        val filter = LiveQuadFilter()
        for (index in 0 until 12) {
            val dx = if (index % 2 == 0) 2.0 else -2.0
            val out = filter.update(LiveFrames.sheetMoved(dx), index * 100.0, 400.0)
            if (index == 0) {
                assertNull(out.shown)
                assertEquals(LiveFrames.sheetMoved(2.0), out.page)
            } else {
                val shown = out.shown!!
                assertEquals(shown, out.page)
                if (index >= 3) assertTrue("at $index", shown.maxCornerDistance(LiveFrames.sheet) <= 1.0)
            }
        }
    }

    @Test
    fun theFilterFollowsARealMoveAndBelievesAJumpOnItsSecondSighting() {
        val filter = LiveQuadFilter()
        filter.update(LiveFrames.sheet, 0.0, 400.0)
        filter.update(LiveFrames.sheet, 100.0, 400.0)
        // Slid 10 px (more than jitter, less than a jump): followed at once.
        val slid = filter.update(LiveFrames.sheetMoved(10.0), 200.0, 400.0)
        assertEquals(LiveFrames.sheetMoved(10.0), slid.shown)
        assertEquals(LiveFrames.sheetMoved(10.0), slid.page)
        // Jumped 40 px (10 %): passed over once, then followed when found there again.
        val jumped = filter.update(LiveFrames.sheetMoved(50.0), 300.0, 400.0)
        assertNull(jumped.page)
        assertEquals(LiveFrames.sheetMoved(10.0), jumped.shown)
        val again = filter.update(LiveFrames.sheetMoved(51.0), 400.0, 400.0)
        assertEquals(LiveFrames.sheetMoved(51.0), again.shown)
        assertEquals(LiveFrames.sheetMoved(51.0), again.page)
        // A jump seen once only (a stray outline) changes nothing.
        filter.update(LiveFrames.sheetMoved(51.0), 500.0, 400.0)
        val stray = filter.update(LiveFrames.sheetMoved(-60.0), 600.0, 400.0)
        assertNull(stray.page)
        assertEquals(LiveFrames.sheetMoved(51.0), stray.shown)
        // Corners named from another edge are the same page, not a jump.
        val sheet = LiveFrames.sheetMoved(51.0)
        val renamed = Quad(sheet.bottomLeft, sheet.topLeft, sheet.topRight, sheet.bottomRight)
        assertEquals(sheet, filter.update(renamed, 700.0, 400.0).shown)
    }

    @Test
    fun theFilterHoldsALostPageThenClearsIt() {
        val filter = LiveQuadFilter()
        filter.update(LiveFrames.sheet, 0.0, 400.0)
        filter.update(LiveFrames.sheet, 100.0, 400.0)
        // Missed: kept for 300 ms after it was last found, with no page for the shutter.
        for (t in listOf(200.0, 300.0, 400.0)) {
            val missed = filter.update(null, t, 400.0)
            assertNull(missed.page)
            assertEquals("at $t", LiveFrames.sheet, missed.shown)
        }
        assertNull(filter.update(null, 500.0, 400.0).shown)
        // Found again after that: a new page, drawn from its second sighting.
        val first = filter.update(LiveFrames.sheet, 600.0, 400.0)
        assertNull(first.shown)
        assertEquals(LiveFrames.sheet, first.page)
        assertEquals(LiveFrames.sheet, filter.update(LiveFrames.sheet, 700.0, 400.0).shown)
    }

    @Test
    fun theFrameScalerAveragesFourPixelsOfEachBlockAndTurnsBGRAIntoRGBA() {
        // 8 x 6 BGRA, 40 bytes a row (8 bytes of padding): blue = x, green = y, red = 10x + y.
        val width = 8
        val height = 6
        val bytesPerRow = 40
        val bytes = ByteArray(bytesPerRow * height)
        for (y in 0 until height) {
            for (x in 0 until width) {
                val o = y * bytesPerRow + x * 4
                bytes[o] = x.toByte()
                bytes[o + 1] = y.toByte()
                bytes[o + 2] = (10 * x + y).toByte()
                bytes[o + 3] = -1
            }
        }
        // At most 4 px long: blocks of 2 x 2, all four pixels averaged.
        val image = FrameScaler.downscaled(bytes, width, height, bytesPerRow, 4)!!
        assertEquals(4, image.width)
        assertEquals(3, image.height)
        // Pixel (1, 2) covers x 2..3, y 4..5: red (24 + 34 + 25 + 35) / 4 = 29.5, half up.
        val o = (2 * 4 + 1) * 4
        assertEquals(30, image.pixels[o].toInt() and 0xFF)
        assertEquals(5, image.pixels[o + 1].toInt() and 0xFF)
        assertEquals(3, image.pixels[o + 2].toInt() and 0xFF)
        assertEquals(255, image.pixels[o + 3].toInt() and 0xFF)
        // Small enough already: kept pixel for pixel.
        val whole = FrameScaler.downscaled(bytes, width, height, bytesPerRow, 480)!!
        assertEquals(8, whole.width)
        assertEquals(6, whole.height)
        val p = (3 * 8 + 5) * 4
        assertEquals(53, whole.pixels[p].toInt() and 0xFF)
        assertEquals(3, whole.pixels[p + 1].toInt() and 0xFF)
        assertEquals(5, whole.pixels[p + 2].toInt() and 0xFF)
        // Too few bytes, or rows too short: refused.
        assertNull(FrameScaler.downscaled(bytes, width, height + 1, bytesPerRow, 4))
        assertNull(FrameScaler.downscaled(bytes, width, height, 16, 4))
    }

    @Test
    fun aLiveOutlineIsTurnedIntoTheUprightPhoto() {
        val outline = Quad(Pt(0.1, 0.2), Pt(0.5, 0.2), Pt(0.5, 0.6), Pt(0.1, 0.6))
        assertQuad(LiveQuadTracker.photoOutline(outline, 0), outline, 1e-12)
        assertQuad(LiveQuadTracker.photoOutline(outline, 360), outline, 1e-12)
        // A quarter clockwise (the phone held upright): the sensor's top left is the photo's top right.
        val quarter = Quad(Pt(0.4, 0.1), Pt(0.8, 0.1), Pt(0.8, 0.5), Pt(0.4, 0.5))
        assertQuad(LiveQuadTracker.photoOutline(outline, 90), quarter, 1e-12)
        assertQuad(LiveQuadTracker.photoOutline(outline, -270), quarter, 1e-12)
        val half = Quad(Pt(0.5, 0.4), Pt(0.9, 0.4), Pt(0.9, 0.8), Pt(0.5, 0.8))
        assertQuad(LiveQuadTracker.photoOutline(outline, 180), half, 1e-12)
        val threeQuarters = Quad(Pt(0.2, 0.5), Pt(0.6, 0.5), Pt(0.6, 0.9), Pt(0.2, 0.9))
        assertQuad(LiveQuadTracker.photoOutline(outline, 270), threeQuarters, 1e-12)
        // Any other turn is not a photo's.
        assertNull(LiveQuadTracker.photoOutline(outline, 45))
    }

    // The frame turned upright by `RgbaImage.rotatedQuarterTurns` for the model and the corners turned back by
    // `photoOutline` land on the same pixels.
    @Test
    fun cornersFoundOnTheUprightFrameTurnBackOntoTheSensorsPixels() {
        val width = 48
        val height = 36
        val marks = listOf(5 to 4, 40 to 7, 37 to 30, 8 to 27)
        val pixels = ByteArray(width * height * 4)
        marks.forEachIndexed { index, mark ->
            val at = (mark.second * width + mark.first) * 4
            pixels[at] = (100 + index * 40).toByte()
            pixels[at + 3] = -1
        }
        val frame = RgbaImage(width, height, pixels)
        for (turn in listOf(0, 90, 180, 270)) {
            val upright = frame.rotatedQuarterTurns(turn / 90)
            val found = ArrayList<Pt>()
            for (index in 0 until 4) {
                val wanted = 100 + index * 40
                for (at in 0 until upright.width * upright.height) {
                    if ((upright.pixels[at * 4].toInt() and 0xFF) == wanted) {
                        found.add(Pt((at % upright.width + 0.5) / upright.width, (at / upright.width + 0.5) / upright.height))
                    }
                }
            }
            assertEquals("turn $turn", 4, found.size)
            val back = LiveQuadTracker.photoOutline(Quad.fromCorners(found), (360 - turn) % 360)!!
            val sensor = back.scaled(width.toDouble(), height.toDouble())
            for (mark in marks) {
                val cx = mark.first + 0.5
                val cy = mark.second + 0.5
                val nearest = sensor.corners.minOf {
                    val dx = it.x - cx
                    val dy = it.y - cy
                    sqrt(dx * dx + dy * dy)
                }
                assertTrue("turn $turn, mark $mark", nearest < 1e-6)
            }
        }
    }
}
