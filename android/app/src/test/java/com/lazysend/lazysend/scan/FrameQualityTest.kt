package com.lazysend.lazysend.scan

import org.junit.Assert.assertEquals
import org.junit.Test

private fun judged(frame: RgbaImage): CaptureQuality {
    val reading = FrameQuality.measure(frame, QualityFrames.sheet)
    return CaptureStability.judge(reading.sharpness, reading.brightness)
}

class FrameQualityTest {
    @Test
    fun theFramesAreTheSharedPixels() {
        assertEquals(0x44CA3AC5L, PhotoScenes.checksum(QualityFrames.frame()))
        assertEquals(0x4DC7DDC5L, PhotoScenes.checksum(QualityFrames.frame(printed = false)))
        assertEquals(0x1EB25E85L, PhotoScenes.checksum(QualityFrames.frame(printed = false, blur = 2)))
        assertEquals(0xCA5C90C9L, PhotoScenes.checksum(QualityFrames.frame(blur = 2)))
        assertEquals(0xCCACDE45L, PhotoScenes.checksum(QualityFrames.frame(dim = 40)))
    }

    private fun assertReading(sharpness: Double, brightness: Double, reading: FrameQualityReading) {
        assertEquals(sharpness, reading.sharpness, 1e-9)
        assertEquals(brightness, reading.brightness, 1e-9)
    }

    @Test
    fun theReadingsAreTakenOverThePage() {
        assertReading(8481.175490779298, 172.04818560380727,
            FrameQuality.measure(QualityFrames.frame(), QualityFrames.sheet))
        assertReading(3013.975159875271, 112.88583333333334, FrameQuality.measure(QualityFrames.frame()))
        assertReading(689.5895300416419, 195.2177275431291,
            FrameQuality.measure(QualityFrames.frame(printed = false), QualityFrames.sheet))
        assertReading(13.418652532892908, 195.2177275431291,
            FrameQuality.measure(QualityFrames.frame(printed = false, blur = 2), QualityFrames.sheet))
        assertReading(189.7358715050565, 26.668054729327782,
            FrameQuality.measure(QualityFrames.frame(dim = 40), QualityFrames.sheet))
    }

    @Test
    fun aSharpLitPageIsGoodABlurredOneBlurryADarkOneDark() {
        assertEquals(CaptureQuality.Good, judged(QualityFrames.frame()))
        // A blank page is sharp by its own edges.
        assertEquals(CaptureQuality.Good, judged(QualityFrames.frame(printed = false)))
        assertEquals(CaptureQuality.Blurry, judged(QualityFrames.frame(printed = false, blur = 2)))
        assertEquals(CaptureQuality.Dark, judged(QualityFrames.frame(dim = 40)))
    }

    @Test
    fun theAreaIsThePagesBoxWithAMargin() {
        assertEquals(FrameQualityArea(78, 38, 242, 202), FrameQuality.area(QualityFrames.sheet, 320, 240))
        val tilted = Quad(Pt(10.5, -4.0), Pt(300.2, 20.0), Pt(330.0, 230.1), Pt(4.0, 250.0))
        assertEquals(FrameQualityArea(2, 0, 320, 240), FrameQuality.area(tilted, 320, 240))
        val inside = Quad(Pt(100.4, 50.6), Pt(150.0, 50.6), Pt(150.0, 90.2), Pt(100.4, 90.2))
        assertEquals(FrameQualityArea(98, 48, 152, 93), FrameQuality.area(inside, 320, 240))
        assertEquals(FrameQualityArea(0, 0, 320, 240), FrameQuality.area(null, 320, 240))
        // Nothing of it in the frame, or not a number: the whole frame.
        val outside = Quad(Pt(400.0, 300.0), Pt(500.0, 300.0), Pt(500.0, 400.0), Pt(400.0, 400.0))
        assertEquals(FrameQualityArea(0, 0, 320, 240), FrameQuality.area(outside, 320, 240))
        val broken = Quad(Pt(Double.NaN, 0.0), Pt(10.0, 0.0), Pt(10.0, 10.0), Pt(0.0, 10.0))
        assertEquals(FrameQualityArea(0, 0, 320, 240), FrameQuality.area(broken, 320, 240))
    }

    @Test
    fun theSharpnessIsTheVarianceOfTheLaplacian() {
        // One bright pixel in the middle of 5 x 5: over the 3 x 3 inner pixels the Laplacian is 400 at the
        // middle, -100 at its four neighbors and 0 at the corners: mean 0, variance 200000 / 9.
        val pixels = ByteArray(25)
        pixels[12] = 100
        val reading = FrameQuality.measure(GrayImage(5, 5, pixels))
        assertEquals(200_000.0 / 9.0, reading.sharpness, 1e-9)
        assertEquals(4.0, reading.brightness, 1e-9)
        // A flat frame has none; a frame too small for a neighborhood has none either.
        assertEquals(0.0, FrameQuality.measure(GrayImage.filled(8, 6, 90)).sharpness, 0.0)
        assertEquals(0.0, FrameQuality.measure(GrayImage.filled(2, 2, 90)).sharpness, 0.0)
        assertEquals(90.0, FrameQuality.measure(GrayImage.filled(2, 2, 90)).brightness, 0.0)
    }

    @Test
    fun theShutterFiresOnlyWhenThePageIsSteadySharpAndLit() {
        // The sheet held still (+-1 px) through a scripted sequence at 10 frames a second: blurred while the
        // camera focuses (frames 0-11), then too dark (12-17), then sharp and lit (18-29), then the same page
        // still there (30-39), then moved away and held still again (40-59).
        val blurred = QualityFrames.frame(printed = false, blur = 2)
        val dark = QualityFrames.frame(dim = 40)
        val sharp = QualityFrames.frame()
        val stability = CaptureStability()
        val fired = ArrayList<Int>()
        val log = ArrayList<CaptureDecision>()
        for (i in 0 until 60) {
            val frame = if (i < 12) blurred else if (i < 18) dark else sharp
            var dx = if (i % 2 == 0) 1.0 else -1.0
            if (i >= 40) dx += 70
            val quad = LiveFrames.sheetMoved(dx)
            val reading = FrameQuality.measure(frame, quad)
            val observation = CaptureObservation(quad, 0.9, i * 100.0, QualityFrames.width, QualityFrames.height,
                reading.sharpness, reading.brightness)
            val decision = stability.update(observation)
            log.add(decision)
            if (decision.shouldCapture) fired.add(i)
        }
        // Held still from frame 1, long enough by frame 7: blurred and then dark, it waits; the first sharp,
        // lit frame is taken; the same page is not taken again; moved 70 px (more than 15 % of the 400 px
        // diagonal), it is a new page: steady from 41, taken at 47.
        assertEquals(listOf(18, 47), fired)
        assertEquals(CaptureQuality.Blurry, log[7].quality)
        assertEquals(CaptureState.Steadying, log[11].state)
        assertEquals(1.0, log[11].progress, 0.0)
        assertEquals(CaptureQuality.Dark, log[12].quality)
        assertEquals(CaptureState.Steadying, log[17].state)
        assertEquals(CaptureState.Captured, log[30].state)
    }
}
