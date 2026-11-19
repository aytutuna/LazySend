#if os(iOS)
import CoreGraphics
import Foundation
import LazySendScan

/// What the corner editor shows and does, without a screen: the photo fitted into the view (and zoomed and panned), the
/// four corners (in the photo's pixels, top-left origin) and which handle a finger moves (a corner, or the middle of an
/// edge, which moves both of its corners), and where the magnifier sits. `PageFinder.movedCorner` keeps the corners in the
/// photo and on a convex outline; the magnifier sits diagonally away from the page's middle, and a corner moves by how
/// far the finger moves, so it is never hidden under the finger.
struct CornerEditorModel: Equatable {
    /// How far from a handle's center a touch still takes it (points).
    static let handleHitRadius: CGFloat = 36
    /// The same for the bar in the middle of an edge, which a corner in reach wins over.
    static let edgeHitRadius: CGFloat = 28
    /// The most the photo is zoomed.
    static let maxZoom: CGFloat = 5
    /// The magnifier's diameter (points), its zoom over the fitted photo (not the zoomed one), and its gap from the corner.
    static let loupeSize: CGFloat = 120
    static let loupeZoom: CGFloat = 2.5
    static let loupeGap: CGFloat = 28
    /// The margin around the fitted photo (points), so a handle on the photo's edge can be reached.
    static let inset: CGFloat = 24

    let photoWidth: Int
    let photoHeight: Int
    /// The corners the editor opened with, for Reset.
    let start: Quad
    /// The corners as placed (0 top-left … 3 bottom-left, as placed).
    private(set) var corners: Quad
    /// The handle the magnifier shows and the last one moved: 0 to 3 a corner, 4 to 7 the middle of the
    /// edge from corner 0 to 1, 1 to 2, 2 to 3 and 3 to 0.
    private(set) var selected: Int = 0
    /// The handle a finger is moving, if any.
    private(set) var dragging: Int?
    /// Where the moved corner was when the finger came down, in the photo's pixels.
    private var dragOrigin: CGPoint = .zero
    /// The same for the two corners of a moved edge.
    private var edgeOrigin: [CGPoint] = []
    /// How far the photo is zoomed (1 to `maxZoom`) and how far it is moved from the view's middle.
    private(set) var zoom: CGFloat = 1
    private(set) var pan: CGSize = .zero
    private var zoomOrigin: CGFloat = 1
    private var panOrigin: CGSize = .zero
    /// Where the touch handled now came down, so a new touch is told from the old one after a cancel.
    private var touchStart: CGPoint?
    /// A finger moves the photo (it came down away from every handle while zoomed in).
    private var panning: Bool = false
    /// A pinch is under way.
    private(set) var isPinching: Bool = false

    init(photoWidth: Int, photoHeight: Int, corners: Quad) {
        self.photoWidth = max(photoWidth, 1)
        self.photoHeight = max(photoHeight, 1)
        self.start = corners
        self.corners = corners
    }

    /// The magnifier shows while a corner is moved.
    var showsLoupe: Bool { dragging != nil }

    /// Reset would change the corners.
    var canReset: Bool { corners != start || zoom != 1 || pan != .zero }

    /// The page can be cut out along the corners (`PageFinder.canUseCorners`).
    var canUseCorners: Bool { PageFinder.canUseCorners(corners) }

    /// Back to the corners the editor opened with, and the photo unzoomed.
    mutating func reset() {
        corners = start
        dragging = nil
        panning = false
        zoom = 1
        pan = .zero
    }

    // MARK: Fitting the photo

    /// The photo fitted into a view of `size`, `inset` in from each side, centered (aspect fit).
    func fittedFrame(in size: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: CornerEditorModel.inset, dy: CornerEditorModel.inset)
        guard bounds.width > 0, bounds.height > 0 else { return CGRect(origin: .zero, size: .zero) }
        let w: CGFloat = CGFloat(photoWidth)
        let h: CGFloat = CGFloat(photoHeight)
        let scale: CGFloat = min(bounds.width / w, bounds.height / h)
        let fittedWidth: CGFloat = w * scale
        let fittedHeight: CGFloat = h * scale
        return CGRect(x: bounds.midX - fittedWidth / 2, y: bounds.midY - fittedHeight / 2,
                      width: fittedWidth, height: fittedHeight)
    }

    /// The photo as shown: the fitted frame zoomed about the view's middle and moved by the pan. Handles,
    /// the outline and the magnifier are drawn into it; the corners stay in the photo's pixels.
    func shownFrame(in size: CGSize) -> CGRect {
        CornerEditorModel.zoomed(fittedFrame(in: size), zoom: zoom, pan: pan, in: size)
    }

    private static func zoomed(_ base: CGRect, zoom: CGFloat, pan: CGSize, in size: CGSize) -> CGRect {
        let middleX: CGFloat = size.width / 2
        let middleY: CGFloat = size.height / 2
        return CGRect(x: middleX + (base.minX - middleX) * zoom + pan.width,
                      y: middleY + (base.minY - middleY) * zoom + pan.height,
                      width: base.width * zoom, height: base.height * zoom)
    }

    /// `pan` kept so the photo still covers the view's middle at `zoom`; none while the photo is not zoomed.
    private func clampedPan(_ pan: CGSize, zoom: CGFloat, in size: CGSize) -> CGSize {
        guard zoom > 1 else { return .zero }
        let base: CGRect = fittedFrame(in: size)
        let middleX: CGFloat = size.width / 2
        let middleY: CGFloat = size.height / 2
        return CGSize(width: min(max(pan.width, -(base.maxX - middleX) * zoom), -(base.minX - middleX) * zoom),
                      height: min(max(pan.height, -(base.maxY - middleY) * zoom), -(base.minY - middleY) * zoom))
    }

    /// A point of the photo (pixels) in the view.
    func viewPoint(_ imagePoint: CGPoint, frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + imagePoint.x / CGFloat(photoWidth) * frame.width,
                y: frame.minY + imagePoint.y / CGFloat(photoHeight) * frame.height)
    }

    /// A point of the view in the photo (pixels).
    func imagePoint(_ viewPoint: CGPoint, frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(x: (viewPoint.x - frame.minX) / frame.width * CGFloat(photoWidth),
                       y: (viewPoint.y - frame.minY) / frame.height * CGFloat(photoHeight))
    }

    /// The corners in the view, in order.
    func viewCorners(frame: CGRect) -> [CGPoint] {
        var points: [CGPoint] = []
        for index in 0..<4 {
            points.append(viewPoint(corners[index], frame: frame))
        }
        return points
    }

    // MARK: Moving a corner

    /// Where handle `index` sits in the view: a corner, or the middle of an edge.
    func handlePoint(_ index: Int, frame: CGRect) -> CGPoint {
        if index < 4 { return viewPoint(corners[index], frame: frame) }
        let a: CGPoint = viewPoint(corners[index & 3], frame: frame)
        let b: CGPoint = viewPoint(corners[(index + 1) & 3], frame: frame)
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// The edge handles (4 to 7) that are drawn and can be taken: an edge too short to keep its middle
    /// clear of both corners leaves the corners to be picked.
    func shownEdges(frame: CGRect) -> [Int] {
        var shown: [Int] = []
        for index in 4..<8 {
            let a: CGPoint = viewPoint(corners[index & 3], frame: frame)
            let b: CGPoint = viewPoint(corners[(index + 1) & 3], frame: frame)
            if hypot(a.x - b.x, a.y - b.y) / 2 > CornerEditorModel.edgeHitRadius {
                shown.append(index)
            }
        }
        return shown
    }

    /// The handle under `location` (the nearest when handles overlap); nil for none. A corner in reach
    /// wins over an edge.
    func handle(at location: CGPoint, frame: CGRect) -> Int? {
        var best: Int?
        var bestDistance: CGFloat = CornerEditorModel.handleHitRadius
        for index in 0..<4 {
            let point: CGPoint = handlePoint(index, frame: frame)
            let distance: CGFloat = hypot(point.x - location.x, point.y - location.y)
            if distance < bestDistance || (best == nil && distance <= bestDistance) {
                bestDistance = distance
                best = index
            }
        }
        if best != nil { return best }
        bestDistance = CornerEditorModel.edgeHitRadius
        for index in shownEdges(frame: frame) {
            let point: CGPoint = handlePoint(index, frame: frame)
            let distance: CGFloat = hypot(point.x - location.x, point.y - location.y)
            if distance < bestDistance || (best == nil && distance <= bestDistance) {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// A finger came down at `location`: the handle under it, if any, starts moving. False when no
    /// handle is there.
    @discardableResult
    mutating func beginDrag(at location: CGPoint, frame: CGRect) -> Bool {
        guard let index = handle(at: location, frame: frame) else { return false }
        dragging = index
        selected = index
        if index < 4 {
            dragOrigin = corners[index]
        } else {
            edgeOrigin = [corners[index & 3], corners[(index + 1) & 3]]
        }
        return true
    }

    /// The finger that came down at `start` is at `location`: the corner moves by as much (in the
    /// photo's pixels), kept within the photo and on a convex outline (`PageFinder.movedCorner`). An
    /// edge moves along its normal by the finger's part along it, both of its corners together.
    mutating func drag(from start: CGPoint, to location: CGPoint, frame: CGRect) {
        guard let index = dragging, frame.width > 0, frame.height > 0 else { return }
        let dx: CGFloat = (location.x - start.x) / frame.width * CGFloat(photoWidth)
        let dy: CGFloat = (location.y - start.y) / frame.height * CGFloat(photoHeight)
        if index < 4 {
            let target = CGPoint(x: dragOrigin.x + dx, y: dragOrigin.y + dy)
            corners = PageFinder.movedCorner(corners, index: index, to: target, width: photoWidth, height: photoHeight)
            return
        }
        guard let normal = CornerEditorModel.normal(from: edgeOrigin[0], to: edgeOrigin[1]) else { return }
        moveEdge(index, from: edgeOrigin, by: dx * normal.x + dy * normal.y)
    }

    /// The finger lifted, or the touch was cancelled.
    mutating func endDrag() {
        dragging = nil
        panning = false
    }

    /// A touch that came down at `start` is at `location`. A touch that differs from the one handled
    /// ends that one first (a cancelled touch never reports its end), then takes the handle under it,
    /// or moves the zoomed photo when none is there.
    mutating func touchMoved(start: CGPoint, to location: CGPoint, frame: CGRect, size: CGSize) {
        if touchStart != start {
            endDrag()
            touchStart = start
            if !isPinching && !beginDrag(at: start, frame: frame) && zoom > 1 {
                panning = true
                panOrigin = pan
            }
        }
        if dragging != nil {
            drag(from: start, to: location, frame: frame)
        } else if panning {
            let moved = CGSize(width: panOrigin.width + location.x - start.x, height: panOrigin.height + location.y - start.y)
            pan = clampedPan(moved, zoom: zoom, in: size)
        }
    }

    /// The touch ended or was cancelled.
    mutating func touchEnded() {
        endDrag()
        touchStart = nil
    }

    /// A pinch starts; one that comes while a handle is held is ignored.
    mutating func beginPinch() {
        guard dragging == nil else { return }
        isPinching = true
        panning = false
        zoomOrigin = zoom
        panOrigin = pan
    }

    /// The pinch is at `scale` of where it began: the photo is zoomed by as much about `anchor`, which
    /// stays over the same point of the photo.
    mutating func pinch(by scale: CGFloat, around anchor: CGPoint, size: CGSize) {
        guard isPinching else { return }
        let base: CGRect = fittedFrame(in: size)
        let from: CGRect = CornerEditorModel.zoomed(base, zoom: zoomOrigin, pan: panOrigin, in: size)
        let target: CGFloat = min(max(zoomOrigin * scale, 1), CornerEditorModel.maxZoom)
        let ratio: CGFloat = target / zoomOrigin
        let origin = CGPoint(x: anchor.x - (anchor.x - from.minX) * ratio, y: anchor.y - (anchor.y - from.minY) * ratio)
        let plain: CGRect = CornerEditorModel.zoomed(base, zoom: target, pan: .zero, in: size)
        let moved = CGSize(width: origin.x - plain.minX, height: origin.y - plain.minY)
        zoom = target
        pan = clampedPan(moved, zoom: target, in: size)
    }

    mutating func endPinch() {
        isPinching = false
    }

    /// The unit normal of the edge from `a` to `b`; nil when they meet.
    private static func normal(from a: CGPoint, to b: CGPoint) -> CGPoint? {
        let length: CGFloat = hypot(b.x - a.x, b.y - a.y)
        guard length > 0 else { return nil }
        return CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
    }

    /// Edge handle `index` moved `wanted` along its normal from where its corners were (`origin`): as far
    /// as keeps both in the photo and on a convex outline, the corners moved in turn by
    /// `PageFinder.movedCorner`; the edge stays parallel to where it was, so it stops where either
    /// corner would be held back.
    private mutating func moveEdge(_ index: Int, from origin: [CGPoint], by wanted: CGFloat) {
        guard let normal = CornerEditorModel.normal(from: origin[0], to: origin[1]) else { return }
        var low: CGFloat = -CGFloat.greatestFiniteMagnitude
        var high: CGFloat = CGFloat.greatestFiniteMagnitude
        for point in origin {
            let starts: [CGFloat] = [point.x, point.y]
            let steps: [CGFloat] = [normal.x, normal.y]
            let limits: [CGFloat] = [CGFloat(photoWidth), CGFloat(photoHeight)]
            for axis in 0..<2 where steps[axis] != 0 && starts[axis] > 0 && starts[axis] < limits[axis] {
                let toZero: CGFloat = -starts[axis] / steps[axis]
                let toLimit: CGFloat = (limits[axis] - starts[axis]) / steps[axis]
                low = max(low, min(toZero, toLimit))
                high = min(high, max(toZero, toLimit))
            }
        }
        let full: CGFloat = min(max(wanted, low), high)
        let a: Int = index & 3
        let b: Int = (index + 1) & 3
        var points: [CGPoint] = corners.corners
        points[a] = origin[0]
        points[b] = origin[1]
        let base = Quad(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])
        let width: Int = photoWidth
        let height: Int = photoHeight
        func tried(_ t: CGFloat) -> Quad? {
            let first = CGPoint(x: min(max(origin[0].x + t * normal.x, 0), CGFloat(width)),
                                y: min(max(origin[0].y + t * normal.y, 0), CGFloat(height)))
            let second = CGPoint(x: min(max(origin[1].x + t * normal.x, 0), CGFloat(width)),
                                 y: min(max(origin[1].y + t * normal.y, 0), CGFloat(height)))
            let one: Quad = PageFinder.movedCorner(base, index: a, to: first, width: width, height: height)
            let two: Quad = PageFinder.movedCorner(one, index: b, to: second, width: width, height: height)
            let landed: Bool = hypot(two[a].x - first.x, two[a].y - first.y) < 1e-6
                && hypot(two[b].x - second.x, two[b].y - second.y) < 1e-6
            return landed ? two : nil
        }
        if let moved = tried(full) {
            corners = moved
            return
        }
        var good: CGFloat = 0
        var bad: CGFloat = full
        var best: Quad = base
        for _ in 0..<12 {
            let middle: CGFloat = (good + bad) / 2
            if let moved = tried(middle) {
                good = middle
                best = moved
            } else {
                bad = middle
            }
        }
        corners = best
    }

    // MARK: The magnifier

    /// Where the magnifier's center sits for the selected corner in a view of `size`: diagonally away
    /// from the page's middle, else the first other diagonal that keeps it in the view (the Mac's rule).
    func loupeCenter(frame: CGRect, in size: CGSize) -> CGPoint {
        let points: [CGPoint] = viewCorners(frame: frame)
        let corner: CGPoint = handlePoint(selected, frame: frame)
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for point in points {
            sumX += point.x
            sumY += point.y
        }
        let middle = CGPoint(x: sumX / 4, y: sumY / 4)
        return CornerEditorModel.loupeCenter(corner: corner, middle: middle, in: size)
    }

    /// The magnifier's center for `corner` of a page whose middle is `middle`, in a view of `size`.
    static func loupeCenter(corner: CGPoint, middle: CGPoint, in size: CGSize) -> CGPoint {
        let dx: CGFloat = corner.x >= middle.x ? 1 : -1
        let dy: CGFloat = corner.y >= middle.y ? 1 : -1
        let reach: CGFloat = loupeSize / 2 + loupeGap
        let signsX: [CGFloat] = [dx, -dx, dx, -dx]
        let signsY: [CGFloat] = [dy, dy, -dy, -dy]
        let half: CGFloat = loupeSize / 2
        var last = CGPoint.zero
        for index in 0..<4 {
            let candidate = CGPoint(x: corner.x + signsX[index] * reach, y: corner.y + signsY[index] * reach)
            let fitsX: Bool = candidate.x - half >= 0 && candidate.x + half <= size.width
            let fitsY: Bool = candidate.y - half >= 0 && candidate.y + half <= size.height
            if fitsX && fitsY { return candidate }
            last = candidate
        }
        return last
    }

    /// The offset of the magnified photo inside the magnifier, so the selected handle is at its center;
    /// `frame` is the fitted photo, which the magnifier scales by `loupeZoom`.
    func loupeImageOffset(frame: CGRect) -> CGSize {
        let corner: CGPoint = handlePoint(selected, frame: frame)
        let zoom: CGFloat = CornerEditorModel.loupeZoom
        return CGSize(width: CornerEditorModel.loupeSize / 2 - (corner.x - frame.minX) * zoom,
                      height: CornerEditorModel.loupeSize / 2 - (corner.y - frame.minY) * zoom)
    }

    /// The name of place `index` on an outline (0 top left … 3 bottom left).
    static func cornerName(_ index: Int) -> String {
        switch index & 3 {
        case 0: return String(localized: "Top left corner")
        case 1: return String(localized: "Top right corner")
        case 2: return String(localized: "Bottom right corner")
        default: return String(localized: "Bottom left corner")
        }
    }

    /// VoiceOver's name for corner `index`, from where it sits now: its place once the outline's corners
    /// are named again (`Quad.fromCorners`), so a corner dragged round to the page's top right is read as
    /// the top right one. Each corner gets a name of its own, also when two of them meet.
    func cornerLabel(_ index: Int) -> String {
        CornerEditorModel.cornerName(place(of: index & 3))
    }

    /// Where corner `wanted` sits once the outline's corners are named again (0 top left … 3 bottom left).
    private func place(of wanted: Int) -> Int {
        let points: [CGPoint] = corners.corners
        let named: [CGPoint] = Quad.fromCorners(points).corners
        var taken: [Bool] = [false, false, false, false]
        var place: Int = wanted
        for slot in 0..<4 {
            var original: Int = 0
            while original < 4 {
                if !taken[original] && points[original] == named[slot] {
                    taken[original] = true
                    if original == wanted {
                        place = slot
                    }
                    break
                }
                original += 1
            }
        }
        return place
    }

    /// The side of the page edge handle `index` (4 to 7) is on now: 0 top, 1 right, 2 bottom, 3 left.
    private func side(of index: Int) -> Int {
        let a: Int = place(of: index & 3)
        let b: Int = place(of: (index + 1) & 3)
        switch (min(a, b), max(a, b)) {
        case (0, 1): return 0
        case (1, 2): return 1
        case (2, 3): return 2
        default: return 3
        }
    }

    /// VoiceOver's name for edge handle `index` (4 to 7), from the side it is on now.
    func edgeLabel(_ index: Int) -> String {
        switch side(of: index) {
        case 0: return String(localized: "Top edge")
        case 1: return String(localized: "Right edge")
        case 2: return String(localized: "Bottom edge")
        default: return String(localized: "Left edge")
        }
    }

    /// VoiceOver's value for edge handle `index`: how far its middle is from the side it is named for, in
    /// percent of the photo.
    func edgeValue(_ index: Int) -> String {
        let a: CGPoint = corners[index & 3]
        let b: CGPoint = corners[(index + 1) & 3]
        let x: Double = Double(a.x + b.x) / 2 / Double(photoWidth) * 100
        let y: Double = Double(a.y + b.y) / 2 / Double(photoHeight) * 100
        switch side(of: index) {
        case 0:
            let top: Int = Int(y.rounded())
            return String(localized: "\(top) percent from the top")
        case 1:
            let right: Int = Int((100 - x).rounded())
            return String(localized: "\(right) percent from the right")
        case 2:
            let bottom: Int = Int((100 - y).rounded())
            return String(localized: "\(bottom) percent from the bottom")
        default:
            let left: Int = Int(x.rounded())
            return String(localized: "\(left) percent from the left")
        }
    }

    /// VoiceOver's value for corner `index`: where it is, in percent of the photo's width and height,
    /// "12 percent from the left, 8 percent from the top"; read again after each step, so a step that
    /// the photo's edge stopped is heard too.
    func cornerValue(_ index: Int) -> String {
        let point: CGPoint = corners[index & 3]
        let left: Int = Int((Double(point.x) / Double(photoWidth) * 100).rounded())
        let top: Int = Int((Double(point.y) / Double(photoHeight) * 100).rounded())
        return String(localized: "\(left) percent from the left, \(top) percent from the top")
    }

    /// Corner `index` moved one step with VoiceOver's swipe up or down: `outward` away from the page's
    /// middle, else towards it, a hundredth of the photo's long side along both axes.
    mutating func nudge(_ index: Int, outward: Bool) {
        let points: [CGPoint] = corners.corners
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for point in points {
            sumX += point.x
            sumY += point.y
        }
        let at: CGPoint = corners[index & 3]
        let step: CGFloat = CGFloat(max(photoWidth, photoHeight)) / 100
        let sign: CGFloat = outward ? 1 : -1
        let dx: CGFloat = at.x >= sumX / 4 ? sign * step : -sign * step
        let dy: CGFloat = at.y >= sumY / 4 ? sign * step : -sign * step
        selected = index & 3
        corners = PageFinder.movedCorner(corners, index: index & 3, to: CGPoint(x: at.x + dx, y: at.y + dy),
                                          width: photoWidth, height: photoHeight)
    }

    /// Corner `index` moved along one axis: `dx` and `dy` are -1, 0 or 1 steps of a hundredth of the
    /// photo's long side (a fifth of that when `fine`), for VoiceOver's named actions and the arrow keys.
    mutating func shift(_ index: Int, dx: Int, dy: Int, fine: Bool = false) {
        let at: CGPoint = corners[index & 3]
        let step: CGFloat = CGFloat(max(photoWidth, photoHeight)) / (fine ? 500 : 100)
        selected = index & 3
        corners = PageFinder.movedCorner(corners, index: index & 3, to: CGPoint(x: at.x + CGFloat(dx) * step, y: at.y + CGFloat(dy) * step),
                                          width: photoWidth, height: photoHeight)
    }

    /// Makes corner `index` the one the arrow keys move.
    mutating func select(_ index: Int) {
        selected = index & 3
    }

    /// Edge handle `index` (4 to 7) moved one step with VoiceOver's swipe up or down: `outward` away
    /// from the page's middle, else towards it, a hundredth of the photo's long side along its normal.
    mutating func nudgeEdge(_ index: Int, outward: Bool) {
        let a: CGPoint = corners[index & 3]
        let b: CGPoint = corners[(index + 1) & 3]
        guard let normal = CornerEditorModel.normal(from: a, to: b) else { return }
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for point in corners.corners {
            sumX += point.x
            sumY += point.y
        }
        let away: CGFloat = normal.x * ((a.x + b.x) / 2 - sumX / 4) + normal.y * ((a.y + b.y) / 2 - sumY / 4)
        let step: CGFloat = CGFloat(max(photoWidth, photoHeight)) / 100
        let sign: CGFloat = (away >= 0) == outward ? 1 : -1
        selected = index
        moveEdge(index, from: [a, b], by: sign * step)
    }
}
#endif
