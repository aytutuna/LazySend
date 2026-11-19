#if os(iOS)
import CoreGraphics
import Foundation
import LazySendScan
import XCTest
@testable import LazySendIOS

// The corner editor without a screen (`CornerEditorModel`): the photo fitted into the view, a finger taking the nearest
// handle and moving its corner by as much as it moves, the corners kept in the photo and on a convex outline, Reset, the
// magnifier kept in the view, and VoiceOver's steps.

/// A 400 × 300 photo with a page outlined inside it.
private let start = Quad(topLeft: CGPoint(x: 80, y: 40), topRight: CGPoint(x: 320, y: 50),
                         bottomRight: CGPoint(x: 330, y: 260), bottomLeft: CGPoint(x: 70, y: 250))

private func model() -> CornerEditorModel {
    CornerEditorModel(photoWidth: 400, photoHeight: 300, corners: start)
}

/// A 448 × 648 view: the photo fits its width (24 pt in from each side) at 1 pt a pixel.
private let viewSize = CGSize(width: 448, height: 648)

final class CornerEditorModelTests: XCTestCase {
    func testThePhotoFitsTheViewCenteredAndPointsMapBothWays() {
        let editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        XCTAssertEqual(frame, CGRect(x: 24, y: 174, width: 400, height: 300))
        // A tall photo in a wide view fits its height.
        let tall = CornerEditorModel(photoWidth: 300, photoHeight: 600, corners: start)
        XCTAssertEqual(tall.fittedFrame(in: CGSize(width: 1000, height: 648)), CGRect(x: 350, y: 24, width: 300, height: 600))
        // No room: nothing to show.
        XCTAssertEqual(editor.fittedFrame(in: CGSize(width: 40, height: 40)), CGRect(x: 0, y: 0, width: 0, height: 0))

        let point = CGPoint(x: 123.5, y: 77.25)
        let shown: CGPoint = editor.viewPoint(point, frame: frame)
        XCTAssertEqual(shown, CGPoint(x: 147.5, y: 251.25))
        let back: CGPoint = editor.imagePoint(shown, frame: frame)
        XCTAssertEqual(Double(back.x), 123.5, accuracy: 1e-9)
        XCTAssertEqual(Double(back.y), 77.25, accuracy: 1e-9)
        let corners: [CGPoint] = editor.viewCorners(frame: frame)
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(corners[0], CGPoint(x: 104, y: 214))
    }

    func testAFingerTakesTheNearestHandleWithinReach() {
        let editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        // The top-right corner is shown at (344, 224).
        XCTAssertEqual(editor.handle(at: CGPoint(x: 350, y: 230), frame: frame), 1)
        XCTAssertEqual(editor.handle(at: CGPoint(x: 344 + 30, y: 224), frame: frame), 1)
        XCTAssertNil(editor.handle(at: CGPoint(x: 344 + 40, y: 224), frame: frame))
        XCTAssertNil(editor.handle(at: CGPoint(x: 224, y: 324), frame: frame))
        // Two handles within reach: the nearer one.
        let close = CornerEditorModel(photoWidth: 400, photoHeight: 300,
                                      corners: Quad(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 140, y: 100),
                                                    bottomRight: CGPoint(x: 140, y: 140), bottomLeft: CGPoint(x: 100, y: 140)))
        XCTAssertEqual(close.handle(at: CGPoint(x: 24 + 132, y: 174 + 102), frame: frame), 1)
        XCTAssertEqual(close.handle(at: CGPoint(x: 24 + 105, y: 174 + 103), frame: frame), 0)
    }

    func testACornerMovesByAsMuchAsTheFingerAndStaysInThePhoto() {
        var editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        XCTAssertFalse(editor.showsLoupe)
        // The finger comes down 10 pt off the bottom-left handle: the corner does not jump to it.
        let down = CGPoint(x: 24 + 70 + 10, y: 174 + 250)
        XCTAssertTrue(editor.beginDrag(at: down, frame: frame))
        XCTAssertEqual(editor.dragging, 3)
        XCTAssertEqual(editor.selected, 3)
        XCTAssertTrue(editor.showsLoupe)
        editor.drag(from: down, to: CGPoint(x: down.x - 20, y: down.y + 15), frame: frame)
        XCTAssertEqual(editor.corners.bottomLeft, CGPoint(x: 50, y: 265))
        // Past the photo's edge it stops at the edge.
        editor.drag(from: down, to: CGPoint(x: down.x - 200, y: down.y + 200), frame: frame)
        XCTAssertEqual(editor.corners.bottomLeft, CGPoint(x: 0, y: 300))
        editor.endDrag()
        XCTAssertNil(editor.dragging)
        XCTAssertFalse(editor.showsLoupe)
        XCTAssertTrue(editor.canReset)
        XCTAssertTrue(editor.canUseCorners)
        // A drag that would fold the outline is not taken.
        XCTAssertTrue(editor.beginDrag(at: editor.viewPoint(editor.corners.topLeft, frame: frame), frame: frame))
        let before: Quad = editor.corners
        let from: CGPoint = editor.viewPoint(editor.corners.topLeft, frame: frame)
        editor.drag(from: from, to: CGPoint(x: from.x + 300, y: from.y + 250), frame: frame)
        XCTAssertEqual(editor.corners, before)
        editor.endDrag()
        // Away from every handle, nothing moves.
        XCTAssertFalse(editor.beginDrag(at: CGPoint(x: 224, y: 324), frame: frame))
        editor.drag(from: CGPoint(x: 224, y: 324), to: CGPoint(x: 260, y: 360), frame: frame)
        XCTAssertEqual(editor.corners, before)
    }

    func testResetAndAnOutlineThePageCannotBeCutAlong() {
        var editor: CornerEditorModel = model()
        XCTAssertFalse(editor.canReset)
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        let down: CGPoint = editor.viewPoint(start.topRight, frame: frame)
        editor.beginDrag(at: down, frame: frame)
        editor.drag(from: down, to: CGPoint(x: down.x + 12, y: down.y - 8), frame: frame)
        editor.endDrag()
        XCTAssertEqual(editor.corners.topRight, CGPoint(x: 332, y: 42))
        editor.reset()
        XCTAssertEqual(editor.corners, start)
        XCTAssertFalse(editor.canReset)
        // An outline the page cannot be cut out along cannot be used.
        let thin = CornerEditorModel(photoWidth: 400, photoHeight: 300,
                                     corners: Quad(topLeft: CGPoint(x: 10, y: 10), topRight: CGPoint(x: 20, y: 10),
                                                   bottomRight: CGPoint(x: 20, y: 200), bottomLeft: CGPoint(x: 10, y: 200)))
        XCTAssertFalse(thin.canUseCorners)
    }

    func testTheMagnifierSitsAwayFromThePageAndStaysInTheView() {
        let size = CGSize(width: 400, height: 600)
        let half: CGFloat = CornerEditorModel.loupeSize / 2
        let reach: CGFloat = half + CornerEditorModel.loupeGap
        // A top-left corner well inside the view: up and to the left of it.
        let inside: CGPoint = CornerEditorModel.loupeCenter(corner: CGPoint(x: 200, y: 300), middle: CGPoint(x: 260, y: 360), in: size)
        XCTAssertEqual(inside, CGPoint(x: 200 - reach, y: 300 - reach))
        // Near the view's top-left: the first diagonal that fits.
        let corner = CGPoint(x: 30, y: 30)
        let near: CGPoint = CornerEditorModel.loupeCenter(corner: corner, middle: CGPoint(x: 200, y: 300), in: size)
        XCTAssertEqual(near, CGPoint(x: 30 + reach, y: 30 + reach))
        XCTAssertGreaterThanOrEqual(near.x - half, 0)
        XCTAssertGreaterThanOrEqual(near.y - half, 0)
        // The magnified photo is placed so the corner is at the magnifier's center.
        var editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        editor.beginDrag(at: editor.viewPoint(start.topLeft, frame: frame), frame: frame)
        let offset: CGSize = editor.loupeImageOffset(frame: frame)
        XCTAssertEqual(Double(offset.width), Double(half - 80 * CornerEditorModel.loupeZoom), accuracy: 1e-9)
        XCTAssertEqual(Double(offset.height), Double(half - 40 * CornerEditorModel.loupeZoom), accuracy: 1e-9)
        // The top-left corner is shown at (104, 214): up and to the left would leave the view, so up
        // and to the right.
        let center: CGPoint = editor.loupeCenter(frame: frame, in: viewSize)
        XCTAssertEqual(center, CGPoint(x: 104 + reach, y: 214 - reach))
    }

    func testVoiceOverNamesTheCornersAndStepsThemOutAndIn() {
        XCTAssertEqual(CornerEditorModel.cornerName(0), "Top left corner")
        XCTAssertEqual(CornerEditorModel.cornerName(2), "Bottom right corner")
        XCTAssertEqual(CornerEditorModel.cornerName(5), "Top right corner")
        var editor: CornerEditorModel = model()
        // A hundredth of the long side (4 px) each way, away from the middle.
        editor.nudge(2, outward: true)
        XCTAssertEqual(editor.corners.bottomRight, CGPoint(x: 334, y: 264))
        XCTAssertEqual(editor.selected, 2)
        editor.nudge(2, outward: false)
        XCTAssertEqual(editor.corners.bottomRight, CGPoint(x: 330, y: 260))
        editor.nudge(0, outward: true)
        XCTAssertEqual(editor.corners.topLeft, CGPoint(x: 76, y: 36))
    }

    func testShiftMovesOneAxisAndSelectPicksTheCorner() {
        var editor: CornerEditorModel = model()
        editor.shift(1, dx: 1, dy: 0)
        XCTAssertEqual(editor.corners.topRight, CGPoint(x: 324, y: 50))
        XCTAssertEqual(editor.selected, 1)
        editor.shift(1, dx: 0, dy: 1, fine: true)
        XCTAssertEqual(editor.corners.topRight.x, 324, accuracy: 0.001)
        XCTAssertEqual(editor.corners.topRight.y, 50.8, accuracy: 0.001)
        editor.select(5)
        XCTAssertEqual(editor.selected, 1)
        for _ in 0..<40 {
            editor.shift(1, dx: 1, dy: -1)
        }
        XCTAssertLessThanOrEqual(editor.corners.topRight.x, 400)
        XCTAssertGreaterThanOrEqual(editor.corners.topRight.y, 0)
    }

    func testVoiceOverNamesEachCornerByWhereItSitsNow() {
        // As found: each corner by its own place.
        let editor: CornerEditorModel = model()
        XCTAssertEqual(editor.cornerLabel(0), "Top left corner")
        XCTAssertEqual(editor.cornerLabel(1), "Top right corner")
        XCTAssertEqual(editor.cornerLabel(2), "Bottom right corner")
        XCTAssertEqual(editor.cornerLabel(3), "Bottom left corner")
        XCTAssertEqual(editor.cornerLabel(4), editor.cornerLabel(0))
        // The outline turned a quarter turn: corner 0 sits at the page's top right now.
        let turned = CornerEditorModel(photoWidth: 400, photoHeight: 300,
                                       corners: Quad(topLeft: start.topRight, topRight: start.bottomRight,
                                                     bottomRight: start.bottomLeft, bottomLeft: start.topLeft))
        XCTAssertEqual(turned.cornerLabel(0), "Top right corner")
        XCTAssertEqual(turned.cornerLabel(1), "Bottom right corner")
        XCTAssertEqual(turned.cornerLabel(2), "Bottom left corner")
        XCTAssertEqual(turned.cornerLabel(3), "Top left corner")
        XCTAssertEqual(turned.cornerValue(0), "80 percent from the left, 17 percent from the top")
        // Corners that meet still get a name each.
        let point = CGPoint(x: 100, y: 100)
        let met = CornerEditorModel(photoWidth: 400, photoHeight: 300,
                                    corners: Quad(topLeft: point, topRight: point, bottomRight: point, bottomLeft: point))
        var names: Set<String> = []
        for index in 0..<4 {
            names.insert(met.cornerLabel(index))
        }
        XCTAssertEqual(names.count, 4)
    }

    func testVoiceOverSaysWhereEachCornerIsAndHearsEachStep() {
        var editor: CornerEditorModel = model()
        // (80, 40) in 400 × 300: 20 % from the left, 13 % from the top.
        XCTAssertEqual(editor.cornerValue(0), "20 percent from the left, 13 percent from the top")
        XCTAssertEqual(editor.cornerValue(2), "83 percent from the left, 87 percent from the top")
        XCTAssertEqual(editor.cornerValue(4), editor.cornerValue(0))
        // A step outward (4 px) changes what is read.
        editor.nudge(0, outward: true)
        XCTAssertEqual(editor.cornerValue(0), "19 percent from the left, 12 percent from the top")
        // At the photo's edge a step changes nothing, and the value says the corner is there.
        var step: Int = 0
        while step < 40 {
            editor.nudge(0, outward: true)
            step += 1
        }
        XCTAssertEqual(editor.corners.topLeft, CGPoint(x: 0, y: 0))
        XCTAssertEqual(editor.cornerValue(0), "0 percent from the left, 0 percent from the top")
    }

    func testTheMiddleOfAnEdgeIsAHandleButACornerInReachWinsOverIt() {
        let editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        // The top edge runs from (80, 40) to (320, 50): its middle is shown at (224, 219).
        let top: CGPoint = editor.handlePoint(4, frame: frame)
        XCTAssertEqual(Double(top.x), 224, accuracy: 1e-9)
        XCTAssertEqual(Double(top.y), 219, accuracy: 1e-9)
        XCTAssertEqual(editor.shownEdges(frame: frame), [4, 5, 6, 7])
        XCTAssertEqual(editor.handle(at: CGPoint(x: 224, y: 219), frame: frame), 4)
        XCTAssertEqual(editor.handle(at: CGPoint(x: 224 + 20, y: 219 + 15), frame: frame), 4)
        XCTAssertNil(editor.handle(at: CGPoint(x: 224, y: 219 + 40), frame: frame))
        XCTAssertEqual(editor.handle(at: editor.handlePoint(7, frame: frame), frame: frame), 7)

        // A touch 20 pt from a corner and 15 pt from the edge's middle takes the corner.
        let page = Quad(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 170, y: 100),
                        bottomRight: CGPoint(x: 170, y: 200), bottomLeft: CGPoint(x: 100, y: 200))
        let wide = CornerEditorModel(photoWidth: 400, photoHeight: 300, corners: page)
        XCTAssertEqual(wide.handle(at: CGPoint(x: 24 + 120, y: 174 + 100), frame: frame), 0)

        // An edge too short to keep its middle clear of both corners has no handle.
        let close = CornerEditorModel(photoWidth: 400, photoHeight: 300,
                                      corners: Quad(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 140, y: 100),
                                                    bottomRight: CGPoint(x: 140, y: 140), bottomLeft: CGPoint(x: 100, y: 140)))
        XCTAssertEqual(close.shownEdges(frame: frame), [])
        XCTAssertEqual(close.handle(at: CGPoint(x: 24 + 120, y: 174 + 100), frame: frame), 0)
    }

    func testAnEdgeMovesAlongItsNormalBothCornersFollowing() {
        var editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        let middle: CGPoint = editor.handlePoint(4, frame: frame)
        XCTAssertTrue(editor.beginDrag(at: middle, frame: frame))
        XCTAssertEqual(editor.dragging, 4)
        XCTAssertEqual(editor.selected, 4)
        XCTAssertTrue(editor.showsLoupe)
        editor.drag(from: middle, to: CGPoint(x: middle.x + 30, y: middle.y - 20), frame: frame)
        // The edge (240, 10) has the normal (-10, 240) / 240.2; only the finger's part along it counts.
        let length: Double = hypot(240, 10)
        let nx: Double = -10 / length
        let ny: Double = 240 / length
        let along: Double = 30 * nx + -20 * ny
        XCTAssertEqual(Double(editor.corners.topLeft.x), 80 + along * nx, accuracy: 1e-6)
        XCTAssertEqual(Double(editor.corners.topLeft.y), 40 + along * ny, accuracy: 1e-6)
        XCTAssertEqual(Double(editor.corners.topRight.x), 320 + along * nx, accuracy: 1e-6)
        XCTAssertEqual(Double(editor.corners.topRight.y), 50 + along * ny, accuracy: 1e-6)
        XCTAssertEqual(editor.corners.bottomRight, start.bottomRight)
        XCTAssertEqual(editor.corners.bottomLeft, start.bottomLeft)
        // The magnifier follows the edge's middle.
        let held: CGPoint = editor.handlePoint(editor.selected, frame: frame)
        XCTAssertEqual(Double(held.x), 24 + Double(editor.corners.topLeft.x + editor.corners.topRight.x) / 2, accuracy: 1e-6)
        XCTAssertEqual(Double(held.y), 174 + Double(editor.corners.topLeft.y + editor.corners.topRight.y) / 2, accuracy: 1e-6)
        editor.endDrag()
        XCTAssertFalse(editor.showsLoupe)
    }

    func testAnEdgeStopsAtThePhotosEdgeAndWhereTheOutlineWouldFold() {
        var editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        let middle: CGPoint = editor.handlePoint(4, frame: frame)
        editor.beginDrag(at: middle, frame: frame)
        // Out past the top of the photo: the higher corner stops at 0, the other keeps the edge parallel.
        editor.drag(from: middle, to: CGPoint(x: middle.x, y: middle.y - 500), frame: frame)
        XCTAssertEqual(Double(editor.corners.topLeft.y), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(editor.corners.topRight.y), 10, accuracy: 1e-6)
        XCTAssertEqual(Double(editor.corners.topLeft.x - 80), Double(editor.corners.topRight.x - 320), accuracy: 1e-6)
        editor.endDrag()

        // In through the bottom edge: it stops short of folding the outline, still parallel to where it was.
        editor.reset()
        editor.beginDrag(at: middle, frame: frame)
        editor.drag(from: middle, to: CGPoint(x: middle.x, y: middle.y + 400), frame: frame)
        XCTAssertTrue(editor.canUseCorners)
        XCTAssertLessThan(editor.corners.topLeft.y, editor.corners.bottomLeft.y)
        XCTAssertGreaterThan(editor.corners.topLeft.y, 40)
        XCTAssertEqual(Double(editor.corners.topLeft.y - 40), Double(editor.corners.topRight.y - 50), accuracy: 1e-6)
    }

    func testAnEdgeWithACornerOnThePhotosBorderSlidesThatCornerAlongIt() {
        var editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        let corner: CGPoint = editor.handlePoint(3, frame: frame)
        editor.beginDrag(at: corner, frame: frame)
        editor.drag(from: corner, to: CGPoint(x: 24 - 100, y: 174 + 400), frame: frame)
        editor.endDrag()
        XCTAssertEqual(Double(editor.corners.bottomLeft.x), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(editor.corners.bottomLeft.y), 300, accuracy: 1e-6)

        let left: CGPoint = editor.handlePoint(7, frame: frame)
        let before: Quad = editor.corners
        XCTAssertTrue(editor.beginDrag(at: left, frame: frame))
        editor.drag(from: left, to: CGPoint(x: left.x + 40, y: left.y), frame: frame)
        XCTAssertNotEqual(editor.corners.topLeft, before.topLeft)
        XCTAssertEqual(Double(editor.corners.bottomLeft.y), 300, accuracy: 1e-6)
    }

    func testZoomLeavesTheCornersInThePhotosPixels() {
        var editor: CornerEditorModel = model()
        let before: CGRect = editor.shownFrame(in: viewSize)
        XCTAssertEqual(before, editor.fittedFrame(in: viewSize))
        let anchor = CGPoint(x: 400, y: 250)
        let under: CGPoint = editor.imagePoint(anchor, frame: before)
        editor.beginPinch()
        editor.pinch(by: 2, around: anchor, size: viewSize)
        editor.endPinch()
        let frame: CGRect = editor.shownFrame(in: viewSize)
        XCTAssertEqual(Double(editor.zoom), 2, accuracy: 1e-9)
        XCTAssertEqual(Double(frame.width), 800, accuracy: 1e-9)
        XCTAssertEqual(Double(frame.height), 600, accuracy: 1e-9)
        XCTAssertEqual(editor.corners, start)
        // The point under the fingers stays under them.
        let still: CGPoint = editor.imagePoint(anchor, frame: frame)
        XCTAssertEqual(Double(still.x), Double(under.x), accuracy: 1e-6)
        XCTAssertEqual(Double(still.y), Double(under.y), accuracy: 1e-6)
        let shown: CGPoint = editor.viewPoint(start.topLeft, frame: frame)
        let back: CGPoint = editor.imagePoint(shown, frame: frame)
        XCTAssertEqual(Double(back.x), 80, accuracy: 1e-6)
        XCTAssertEqual(Double(back.y), 40, accuracy: 1e-6)

        // More than the limit is held at it, less than 1 at 1.
        editor.beginPinch()
        editor.pinch(by: 20, around: anchor, size: viewSize)
        XCTAssertEqual(editor.zoom, CornerEditorModel.maxZoom)
        editor.pinch(by: 0.1, around: anchor, size: viewSize)
        XCTAssertEqual(editor.zoom, 1)
        XCTAssertEqual(editor.pan, .zero)
        editor.endPinch()
        XCTAssertFalse(editor.canReset)

        editor.beginPinch()
        editor.pinch(by: 3, around: anchor, size: viewSize)
        editor.endPinch()
        XCTAssertTrue(editor.canReset)
        editor.reset()
        XCTAssertEqual(editor.zoom, 1)
        XCTAssertEqual(editor.pan, .zero)
        XCTAssertFalse(editor.canReset)
    }

    func testThePanKeepsThePhotoOverTheViewsMiddleAtEveryZoom() {
        let middle = CGPoint(x: 224, y: 324)
        let away = CGPoint(x: 1, y: 1)
        for zoom in [1.0, 2.4, 5.0] {
            var editor: CornerEditorModel = model()
            editor.beginPinch()
            editor.pinch(by: CGFloat(zoom), around: CGPoint(x: 400, y: 250), size: viewSize)
            editor.endPinch()
            for push in [CGPoint(x: 9000, y: 9000), CGPoint(x: -9000, y: -9000), CGPoint(x: 9000, y: -9000)] {
                XCTAssertNil(editor.handle(at: away, frame: editor.shownFrame(in: viewSize)))
                editor.touchMoved(start: away, to: CGPoint(x: away.x + push.x, y: away.y + push.y),
                                  frame: editor.shownFrame(in: viewSize), size: viewSize)
                editor.touchEnded()
                let frame: CGRect = editor.shownFrame(in: viewSize)
                XCTAssertLessThanOrEqual(Double(frame.minX), Double(middle.x) + 1e-9)
                XCTAssertGreaterThanOrEqual(Double(frame.maxX), Double(middle.x) - 1e-9)
                XCTAssertLessThanOrEqual(Double(frame.minY), Double(middle.y) + 1e-9)
                XCTAssertGreaterThanOrEqual(Double(frame.maxY), Double(middle.y) - 1e-9)
                XCTAssertEqual(editor.corners, start)
            }
            if zoom == 1 {
                XCTAssertEqual(editor.pan, .zero)
            } else {
                XCTAssertNotEqual(editor.pan, .zero)
            }
        }
    }

    func testAPinchMovesNoCornerAndIsIgnoredWhileAHandleIsHeld() {
        var editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        let corner: CGPoint = editor.handlePoint(1, frame: frame)
        editor.touchMoved(start: corner, to: CGPoint(x: corner.x + 10, y: corner.y + 10), frame: frame, size: viewSize)
        XCTAssertEqual(editor.dragging, 1)
        editor.beginPinch()
        XCTAssertFalse(editor.isPinching)
        editor.pinch(by: 3, around: corner, size: viewSize)
        XCTAssertEqual(editor.zoom, 1)
        editor.touchEnded()

        let moved: Quad = editor.corners
        editor.beginPinch()
        editor.pinch(by: 3, around: corner, size: viewSize)
        editor.endPinch()
        XCTAssertEqual(editor.corners, moved)
    }

    func testACancelledDragLeavesTheCornerWhereItWasAndTheNextTouchStartsFresh() {
        var editor: CornerEditorModel = model()
        let frame: CGRect = editor.fittedFrame(in: viewSize)
        let topRight: CGPoint = editor.handlePoint(1, frame: frame)
        let bottomLeft: CGPoint = editor.handlePoint(3, frame: frame)
        editor.touchMoved(start: topRight, to: CGPoint(x: topRight.x + 10, y: topRight.y + 10), frame: frame, size: viewSize)
        XCTAssertEqual(editor.corners.topRight, CGPoint(x: 330, y: 60))
        XCTAssertTrue(editor.showsLoupe)
        // No end arrives. The next touch comes down on another corner and moves from its own start.
        editor.touchMoved(start: bottomLeft, to: bottomLeft, frame: frame, size: viewSize)
        XCTAssertEqual(editor.dragging, 3)
        XCTAssertEqual(editor.corners.topRight, CGPoint(x: 330, y: 60))
        XCTAssertEqual(editor.corners.bottomLeft, start.bottomLeft)
        editor.touchMoved(start: bottomLeft, to: CGPoint(x: bottomLeft.x - 5, y: bottomLeft.y), frame: frame, size: viewSize)
        XCTAssertEqual(editor.corners.bottomLeft, CGPoint(x: 65, y: 250))
        XCTAssertEqual(editor.corners.topRight, CGPoint(x: 330, y: 60))
        // The system's cancel ends the touch: the magnifier goes and a touch away from every handle moves nothing.
        editor.touchEnded()
        XCTAssertFalse(editor.showsLoupe)
        let corners: Quad = editor.corners
        let away = CGPoint(x: 224, y: 324)
        editor.touchMoved(start: away, to: CGPoint(x: away.x + 30, y: away.y + 30), frame: frame, size: viewSize)
        XCTAssertNil(editor.dragging)
        XCTAssertEqual(editor.corners, corners)
    }

    func testVoiceOverNamesTheEdgesAndStepsThemOutAndIn() {
        var editor: CornerEditorModel = model()
        XCTAssertEqual(editor.edgeLabel(4), "Top edge")
        XCTAssertEqual(editor.edgeLabel(5), "Right edge")
        XCTAssertEqual(editor.edgeLabel(6), "Bottom edge")
        XCTAssertEqual(editor.edgeLabel(7), "Left edge")
        XCTAssertEqual(editor.edgeValue(4), "15 percent from the top")
        XCTAssertEqual(editor.edgeValue(5), "19 percent from the right")
        XCTAssertEqual(editor.edgeValue(6), "15 percent from the bottom")
        XCTAssertEqual(editor.edgeValue(7), "19 percent from the left")

        // The outline turned a quarter turn: the edge from corner 0 to 1 is the page's right one now.
        let turned = CornerEditorModel(photoWidth: 400, photoHeight: 300,
                                       corners: Quad(topLeft: start.topRight, topRight: start.bottomRight,
                                                     bottomRight: start.bottomLeft, bottomLeft: start.topLeft))
        XCTAssertEqual(turned.edgeLabel(4), "Right edge")

        // A step out moves both corners of the top edge up by a hundredth of the long side, along its normal.
        editor.nudgeEdge(4, outward: true)
        XCTAssertEqual(editor.selected, 4)
        let length: Double = hypot(240, 10)
        XCTAssertEqual(Double(editor.corners.topLeft.y), 40 - 4 * 240 / length, accuracy: 1e-6)
        XCTAssertEqual(Double(editor.corners.topRight.y), 50 - 4 * 240 / length, accuracy: 1e-6)
        XCTAssertEqual(editor.corners.bottomRight, start.bottomRight)
        editor.nudgeEdge(4, outward: false)
        XCTAssertEqual(Double(editor.corners.topLeft.y), 40, accuracy: 1e-6)
        XCTAssertEqual(Double(editor.corners.topRight.x), 320, accuracy: 1e-6)
        // Out and out again reaches the photo's edge and stays there.
        var step: Int = 0
        while step < 30 {
            editor.nudgeEdge(4, outward: true)
            step += 1
        }
        XCTAssertEqual(Double(editor.corners.topLeft.y), 0, accuracy: 1e-6)
    }
}
#endif
