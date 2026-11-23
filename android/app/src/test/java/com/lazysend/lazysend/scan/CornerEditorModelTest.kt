package com.lazysend.lazysend.scan

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.hypot

/** A 400 x 300 photo with a page outlined inside it. */
private val start = Quad(Pt(80.0, 40.0), Pt(320.0, 50.0), Pt(330.0, 260.0), Pt(70.0, 250.0))

private fun model() = CornerEditorModel(400, 300, start)

/** A 448 x 648 view: the photo fits its width (24 pt in from each side) at 1 pt a pixel. */
private val viewSize = ViewSize(448.0, 648.0)

private fun quadOf(a: Pt, b: Pt, c: Pt, d: Pt) = Quad(a, b, c, d)

class CornerEditorModelTest {
    @Test
    fun thePhotoFitsTheViewCenteredAndPointsMapBothWays() {
        val editor = model()
        val frame = editor.fittedFrame(viewSize)
        assertEquals(Rect(24.0, 174.0, 400.0, 300.0), frame)
        // A tall photo in a wide view fits its height.
        val tall = CornerEditorModel(300, 600, start)
        assertEquals(Rect(350.0, 24.0, 300.0, 600.0), tall.fittedFrame(ViewSize(1000.0, 648.0)))
        // No room: nothing to show.
        assertEquals(Rect(0.0, 0.0, 0.0, 0.0), editor.fittedFrame(ViewSize(40.0, 40.0)))

        val point = Pt(123.5, 77.25)
        val shown = editor.viewPoint(point, frame)
        assertEquals(Pt(147.5, 251.25), shown)
        val back = editor.imagePoint(shown, frame)
        assertEquals(123.5, back.x, 1e-9)
        assertEquals(77.25, back.y, 1e-9)
        val corners = editor.viewCorners(frame)
        assertEquals(4, corners.size)
        assertEquals(Pt(104.0, 214.0), corners[0])
    }

    @Test
    fun aFingerTakesTheNearestHandleWithinReach() {
        val editor = model()
        val frame = editor.fittedFrame(viewSize)
        // The top-right corner is shown at (344, 224).
        assertEquals(1, editor.handle(Pt(350.0, 230.0), frame))
        assertEquals(1, editor.handle(Pt(344.0 + 30, 224.0), frame))
        assertNull(editor.handle(Pt(344.0 + 40, 224.0), frame))
        assertNull(editor.handle(Pt(224.0, 324.0), frame))
        // Two handles within reach: the nearer one.
        val close = CornerEditorModel(400, 300, quadOf(Pt(100.0, 100.0), Pt(140.0, 100.0), Pt(140.0, 140.0), Pt(100.0, 140.0)))
        assertEquals(1, close.handle(Pt(24.0 + 132, 174.0 + 102), frame))
        assertEquals(0, close.handle(Pt(24.0 + 105, 174.0 + 103), frame))
    }

    @Test
    fun aCornerMovesByAsMuchAsTheFingerAndStaysInThePhoto() {
        val editor = model()
        val frame = editor.fittedFrame(viewSize)
        assertFalse(editor.showsLoupe)
        // The finger comes down 10 pt off the bottom-left handle: the corner does not jump to it.
        val down = Pt(24.0 + 70 + 10, 174.0 + 250)
        assertTrue(editor.beginDrag(down, frame))
        assertEquals(3, editor.dragging)
        assertEquals(3, editor.selected)
        assertTrue(editor.showsLoupe)
        editor.drag(down, Pt(down.x - 20, down.y + 15), frame)
        assertEquals(Pt(50.0, 265.0), editor.corners.bottomLeft)
        // Past the photo's edge it stops at the edge.
        editor.drag(down, Pt(down.x - 200, down.y + 200), frame)
        assertEquals(Pt(0.0, 300.0), editor.corners.bottomLeft)
        editor.endDrag()
        assertNull(editor.dragging)
        assertFalse(editor.showsLoupe)
        assertTrue(editor.canReset)
        assertTrue(editor.canUseCorners)
        // A drag that would fold the outline is not taken.
        assertTrue(editor.beginDrag(editor.viewPoint(editor.corners.topLeft, frame), frame))
        val before = editor.corners
        val from = editor.viewPoint(editor.corners.topLeft, frame)
        editor.drag(from, Pt(from.x + 300, from.y + 250), frame)
        assertEquals(before, editor.corners)
        editor.endDrag()
        // Away from every handle, nothing moves.
        assertFalse(editor.beginDrag(Pt(224.0, 324.0), frame))
        editor.drag(Pt(224.0, 324.0), Pt(260.0, 360.0), frame)
        assertEquals(before, editor.corners)
    }

    @Test
    fun resetAndAnOutlineThePageCannotBeCutAlong() {
        val editor = model()
        assertFalse(editor.canReset)
        val frame = editor.fittedFrame(viewSize)
        val down = editor.viewPoint(start.topRight, frame)
        editor.beginDrag(down, frame)
        editor.drag(down, Pt(down.x + 12, down.y - 8), frame)
        editor.endDrag()
        assertEquals(Pt(332.0, 42.0), editor.corners.topRight)
        editor.reset()
        assertEquals(start, editor.corners)
        assertFalse(editor.canReset)
        // An outline the page cannot be cut out along cannot be used.
        val thin = CornerEditorModel(400, 300, quadOf(Pt(10.0, 10.0), Pt(20.0, 10.0), Pt(20.0, 200.0), Pt(10.0, 200.0)))
        assertFalse(thin.canUseCorners)
    }

    @Test
    fun theMagnifierSitsAwayFromThePageAndStaysInTheView() {
        val size = ViewSize(400.0, 600.0)
        val half = CornerEditorModel.LOUPE_SIZE / 2
        val reach = half + CornerEditorModel.LOUPE_GAP
        // A top-left corner well inside the view: up and to the left of it.
        val inside = CornerEditorModel.loupeCenter(Pt(200.0, 300.0), Pt(260.0, 360.0), size)
        assertEquals(Pt(200 - reach, 300 - reach), inside)
        // Near the view's top-left: the first diagonal that fits.
        val near = CornerEditorModel.loupeCenter(Pt(30.0, 30.0), Pt(200.0, 300.0), size)
        assertEquals(Pt(30 + reach, 30 + reach), near)
        assertTrue(near.x - half >= 0)
        assertTrue(near.y - half >= 0)
        // The magnified photo is placed so the corner is at the magnifier's center.
        val editor = model()
        val frame = editor.fittedFrame(viewSize)
        editor.beginDrag(editor.viewPoint(start.topLeft, frame), frame)
        val offset = editor.loupeImageOffset(frame)
        assertEquals(half - 80 * CornerEditorModel.LOUPE_ZOOM, offset.width, 1e-9)
        assertEquals(half - 40 * CornerEditorModel.LOUPE_ZOOM, offset.height, 1e-9)
        // The top-left corner is shown at (104, 214): up and to the left would leave the view, so up
        // and to the right.
        assertEquals(Pt(104 + reach, 214 - reach), editor.loupeCenter(frame, viewSize))
    }

    @Test
    fun screenReaderStepsMoveACornerOutAndIn() {
        val editor = model()
        // A hundredth of the long side (4 px) each way, away from the middle.
        editor.nudge(2, outward = true)
        assertEquals(Pt(334.0, 264.0), editor.corners.bottomRight)
        assertEquals(2, editor.selected)
        editor.nudge(2, outward = false)
        assertEquals(Pt(330.0, 260.0), editor.corners.bottomRight)
        editor.nudge(0, outward = true)
        assertEquals(Pt(76.0, 36.0), editor.corners.topLeft)
    }

    @Test
    fun shiftMovesOneAxisAndSelectPicksTheCorner() {
        val editor = model()
        editor.shift(1, 1, 0)
        assertEquals(Pt(324.0, 50.0), editor.corners.topRight)
        assertEquals(1, editor.selected)
        editor.shift(1, 0, 1, fine = true)
        assertEquals(324.0, editor.corners.topRight.x, 0.001)
        assertEquals(50.8, editor.corners.topRight.y, 0.001)
        editor.select(5)
        assertEquals(1, editor.selected)
        repeat(40) { editor.shift(1, 1, -1) }
        assertTrue(editor.corners.topRight.x <= 400)
        assertTrue(editor.corners.topRight.y >= 0)
    }

    @Test
    fun eachCornerIsPlacedByWhereItSitsNow() {
        // As found: each corner by its own place.
        val editor = model()
        for (index in 0 until 4) assertEquals(index, editor.cornerPlace(index))
        assertEquals(editor.cornerPlace(0), editor.cornerPlace(4))
        // The outline turned a quarter turn: corner 0 sits at the page's top right now.
        val turned = CornerEditorModel(400, 300, quadOf(start.topRight, start.bottomRight, start.bottomLeft, start.topLeft))
        assertEquals(1, turned.cornerPlace(0))
        assertEquals(2, turned.cornerPlace(1))
        assertEquals(3, turned.cornerPlace(2))
        assertEquals(0, turned.cornerPlace(3))
        assertEquals(80 to 17, turned.cornerPercents(0))
        // Corners that meet still get a place each.
        val point = Pt(100.0, 100.0)
        val met = CornerEditorModel(400, 300, quadOf(point, point, point, point))
        assertEquals(setOf(0, 1, 2, 3), (0 until 4).map { met.cornerPlace(it) }.toSet())
    }

    @Test
    fun cornerPercentsSayWhereEachCornerIsAndFollowEachStep() {
        val editor = model()
        // (80, 40) in 400 x 300: 20 % from the left, 13 % from the top.
        assertEquals(20 to 13, editor.cornerPercents(0))
        assertEquals(83 to 87, editor.cornerPercents(2))
        assertEquals(editor.cornerPercents(0), editor.cornerPercents(4))
        // A step outward (4 px) changes what is read.
        editor.nudge(0, outward = true)
        assertEquals(19 to 12, editor.cornerPercents(0))
        // At the photo's edge a step changes nothing, and the value says the corner is there.
        repeat(40) { editor.nudge(0, outward = true) }
        assertEquals(Pt(0.0, 0.0), editor.corners.topLeft)
        assertEquals(0 to 0, editor.cornerPercents(0))
    }

    @Test
    fun theMiddleOfAnEdgeIsAHandleButACornerInReachWinsOverIt() {
        val editor = model()
        val frame = editor.fittedFrame(viewSize)
        // The top edge runs from (80, 40) to (320, 50): its middle is shown at (224, 219).
        val top = editor.handlePoint(4, frame)
        assertEquals(224.0, top.x, 1e-9)
        assertEquals(219.0, top.y, 1e-9)
        assertEquals(listOf(4, 5, 6, 7), editor.shownEdges(frame))
        assertEquals(4, editor.handle(Pt(224.0, 219.0), frame))
        assertEquals(4, editor.handle(Pt(224.0 + 20, 219.0 + 15), frame))
        assertNull(editor.handle(Pt(224.0, 219.0 + 40), frame))
        assertEquals(7, editor.handle(editor.handlePoint(7, frame), frame))

        // A touch 20 pt from a corner and 15 pt from the edge's middle takes the corner.
        val wide = CornerEditorModel(400, 300, quadOf(Pt(100.0, 100.0), Pt(170.0, 100.0), Pt(170.0, 200.0), Pt(100.0, 200.0)))
        assertEquals(0, wide.handle(Pt(24.0 + 120, 174.0 + 100), frame))

        // An edge too short to keep its middle clear of both corners has no handle.
        val close = CornerEditorModel(400, 300, quadOf(Pt(100.0, 100.0), Pt(140.0, 100.0), Pt(140.0, 140.0), Pt(100.0, 140.0)))
        assertEquals(emptyList<Int>(), close.shownEdges(frame))
        assertEquals(0, close.handle(Pt(24.0 + 120, 174.0 + 100), frame))
    }

    @Test
    fun anEdgeMovesAlongItsNormalBothCornersFollowing() {
        val editor = model()
        val frame = editor.fittedFrame(viewSize)
        val middle = editor.handlePoint(4, frame)
        assertTrue(editor.beginDrag(middle, frame))
        assertEquals(4, editor.dragging)
        assertEquals(4, editor.selected)
        assertTrue(editor.showsLoupe)
        editor.drag(middle, Pt(middle.x + 30, middle.y - 20), frame)
        // The edge (240, 10) has the normal (-10, 240) / 240.2; only the finger's part along it counts.
        val length = hypot(240.0, 10.0)
        val nx = -10 / length
        val ny = 240 / length
        val along = 30 * nx + -20 * ny
        assertEquals(80 + along * nx, editor.corners.topLeft.x, 1e-6)
        assertEquals(40 + along * ny, editor.corners.topLeft.y, 1e-6)
        assertEquals(320 + along * nx, editor.corners.topRight.x, 1e-6)
        assertEquals(50 + along * ny, editor.corners.topRight.y, 1e-6)
        assertEquals(start.bottomRight, editor.corners.bottomRight)
        assertEquals(start.bottomLeft, editor.corners.bottomLeft)
        // The magnifier follows the edge's middle.
        val held = editor.handlePoint(editor.selected, frame)
        assertEquals(24 + (editor.corners.topLeft.x + editor.corners.topRight.x) / 2, held.x, 1e-6)
        assertEquals(174 + (editor.corners.topLeft.y + editor.corners.topRight.y) / 2, held.y, 1e-6)
        editor.endDrag()
        assertFalse(editor.showsLoupe)
    }

    @Test
    fun anEdgeStopsAtThePhotosEdgeAndWhereTheOutlineWouldFold() {
        val editor = model()
        val frame = editor.fittedFrame(viewSize)
        val middle = editor.handlePoint(4, frame)
        editor.beginDrag(middle, frame)
        // Out past the top of the photo: the higher corner stops at 0, the other keeps the edge parallel.
        editor.drag(middle, Pt(middle.x, middle.y - 500), frame)
        assertEquals(0.0, editor.corners.topLeft.y, 1e-6)
        assertEquals(10.0, editor.corners.topRight.y, 1e-6)
        assertEquals(editor.corners.topLeft.x - 80, editor.corners.topRight.x - 320, 1e-6)
        editor.endDrag()

        // In through the bottom edge: it stops short of folding the outline, still parallel to where it was.
        editor.reset()
        editor.beginDrag(middle, frame)
        editor.drag(middle, Pt(middle.x, middle.y + 400), frame)
        assertTrue(editor.canUseCorners)
        assertTrue(editor.corners.topLeft.y < editor.corners.bottomLeft.y)
        assertTrue(editor.corners.topLeft.y > 40)
        assertEquals(editor.corners.topLeft.y - 40, editor.corners.topRight.y - 50, 1e-6)
    }

    @Test
    fun anEdgeWithACornerOnThePhotosBorderSlidesThatCornerAlongIt() {
        val editor = model()
        val frame = editor.fittedFrame(viewSize)
        val corner = editor.handlePoint(3, frame)
        editor.beginDrag(corner, frame)
        editor.drag(corner, Pt(24.0 - 100, 174.0 + 400), frame)
        editor.endDrag()
        assertEquals(0.0, editor.corners.bottomLeft.x, 1e-6)
        assertEquals(300.0, editor.corners.bottomLeft.y, 1e-6)

        val left = editor.handlePoint(7, frame)
        val before = editor.corners
        assertTrue(editor.beginDrag(left, frame))
        editor.drag(left, Pt(left.x + 40, left.y), frame)
        assertNotEquals(before.topLeft, editor.corners.topLeft)
        assertEquals(300.0, editor.corners.bottomLeft.y, 1e-6)
    }

    @Test
    fun zoomLeavesTheCornersInThePhotosPixels() {
        val editor = model()
        val before = editor.shownFrame(viewSize)
        assertEquals(editor.fittedFrame(viewSize), before)
        val anchor = Pt(400.0, 250.0)
        val under = editor.imagePoint(anchor, before)
        editor.beginPinch()
        editor.pinch(2.0, anchor, viewSize)
        editor.endPinch()
        val frame = editor.shownFrame(viewSize)
        assertEquals(2.0, editor.zoom, 1e-9)
        assertEquals(800.0, frame.width, 1e-9)
        assertEquals(600.0, frame.height, 1e-9)
        assertEquals(start, editor.corners)
        // The point under the fingers stays under them.
        val still = editor.imagePoint(anchor, frame)
        assertEquals(under.x, still.x, 1e-6)
        assertEquals(under.y, still.y, 1e-6)
        val shown = editor.viewPoint(start.topLeft, frame)
        val back = editor.imagePoint(shown, frame)
        assertEquals(80.0, back.x, 1e-6)
        assertEquals(40.0, back.y, 1e-6)

        // More than the limit is held at it, less than 1 at 1.
        editor.beginPinch()
        editor.pinch(20.0, anchor, viewSize)
        assertEquals(CornerEditorModel.MAX_ZOOM, editor.zoom, 0.0)
        editor.pinch(0.1, anchor, viewSize)
        assertEquals(1.0, editor.zoom, 0.0)
        assertEquals(ViewSize.Zero, editor.pan)
        editor.endPinch()
        assertFalse(editor.canReset)

        editor.beginPinch()
        editor.pinch(3.0, anchor, viewSize)
        editor.endPinch()
        assertTrue(editor.canReset)
        editor.reset()
        assertEquals(1.0, editor.zoom, 0.0)
        assertEquals(ViewSize.Zero, editor.pan)
        assertFalse(editor.canReset)
    }

    @Test
    fun thePanKeepsThePhotoOverTheViewsMiddleAtEveryZoom() {
        val middle = Pt(224.0, 324.0)
        val away = Pt(1.0, 1.0)
        for (zoom in listOf(1.0, 2.4, 5.0)) {
            val editor = model()
            editor.beginPinch()
            editor.pinch(zoom, Pt(400.0, 250.0), viewSize)
            editor.endPinch()
            for (push in listOf(Pt(9000.0, 9000.0), Pt(-9000.0, -9000.0), Pt(9000.0, -9000.0))) {
                assertNull(editor.handle(away, editor.shownFrame(viewSize)))
                editor.touchMoved(away, Pt(away.x + push.x, away.y + push.y), editor.shownFrame(viewSize), viewSize)
                editor.touchEnded()
                val frame = editor.shownFrame(viewSize)
                assertTrue(frame.x <= middle.x + 1e-9)
                assertTrue(frame.x + frame.width >= middle.x - 1e-9)
                assertTrue(frame.y <= middle.y + 1e-9)
                assertTrue(frame.y + frame.height >= middle.y - 1e-9)
                assertEquals(start, editor.corners)
            }
            if (zoom == 1.0) assertEquals(ViewSize.Zero, editor.pan) else assertNotEquals(ViewSize.Zero, editor.pan)
        }
    }

    @Test
    fun aPinchMovesNoCornerAndIsIgnoredWhileAHandleIsHeld() {
        val editor = model()
        val frame = editor.fittedFrame(viewSize)
        val corner = editor.handlePoint(1, frame)
        editor.touchMoved(corner, Pt(corner.x + 10, corner.y + 10), frame, viewSize)
        assertEquals(1, editor.dragging)
        editor.beginPinch()
        assertFalse(editor.isPinching)
        editor.pinch(3.0, corner, viewSize)
        assertEquals(1.0, editor.zoom, 0.0)
        editor.touchEnded()

        val moved = editor.corners
        editor.beginPinch()
        editor.pinch(3.0, corner, viewSize)
        editor.endPinch()
        assertEquals(moved, editor.corners)
    }

    @Test
    fun aCancelledDragLeavesTheCornerWhereItWasAndTheNextTouchStartsFresh() {
        val editor = model()
        val frame = editor.fittedFrame(viewSize)
        val topRight = editor.handlePoint(1, frame)
        val bottomLeft = editor.handlePoint(3, frame)
        editor.touchMoved(topRight, Pt(topRight.x + 10, topRight.y + 10), frame, viewSize)
        assertEquals(Pt(330.0, 60.0), editor.corners.topRight)
        assertTrue(editor.showsLoupe)
        // No end arrives. The next touch comes down on another corner and moves from its own start.
        editor.touchMoved(bottomLeft, bottomLeft, frame, viewSize)
        assertEquals(3, editor.dragging)
        assertEquals(Pt(330.0, 60.0), editor.corners.topRight)
        assertEquals(start.bottomLeft, editor.corners.bottomLeft)
        editor.touchMoved(bottomLeft, Pt(bottomLeft.x - 5, bottomLeft.y), frame, viewSize)
        assertEquals(Pt(65.0, 250.0), editor.corners.bottomLeft)
        assertEquals(Pt(330.0, 60.0), editor.corners.topRight)
        // The system's cancel ends the touch: the magnifier goes and a touch away from every handle moves nothing.
        editor.touchEnded()
        assertFalse(editor.showsLoupe)
        val corners = editor.corners
        val away = Pt(224.0, 324.0)
        editor.touchMoved(away, Pt(away.x + 30, away.y + 30), frame, viewSize)
        assertNull(editor.dragging)
        assertEquals(corners, editor.corners)
    }

    @Test
    fun screenReaderNamesAndStepsTheEdges() {
        val editor = model()
        assertEquals(listOf(0, 1, 2, 3), (4 until 8).map { editor.edgeSide(it) })
        assertEquals(listOf(15, 19, 15, 19), (4 until 8).map { editor.edgePercent(it) })

        // The outline turned a quarter turn: the edge from corner 0 to 1 is the page's right one now.
        val turned = CornerEditorModel(400, 300, quadOf(start.topRight, start.bottomRight, start.bottomLeft, start.topLeft))
        assertEquals(1, turned.edgeSide(4))

        // A step out moves both corners of the top edge up by a hundredth of the long side, along its normal.
        editor.nudgeEdge(4, outward = true)
        assertEquals(4, editor.selected)
        val length = hypot(240.0, 10.0)
        assertEquals(40 - 4 * 240 / length, editor.corners.topLeft.y, 1e-6)
        assertEquals(50 - 4 * 240 / length, editor.corners.topRight.y, 1e-6)
        assertEquals(start.bottomRight, editor.corners.bottomRight)
        editor.nudgeEdge(4, outward = false)
        assertEquals(40.0, editor.corners.topLeft.y, 1e-6)
        assertEquals(320.0, editor.corners.topRight.x, 1e-6)
        // Out and out again reaches the photo's edge and stays there.
        repeat(30) { editor.nudgeEdge(4, outward = true) }
        assertEquals(0.0, editor.corners.topLeft.y, 1e-6)
    }
}
