import CoreGraphics
import Foundation

/// Where the page is in a photo, and whether it was found clearly enough to be cut out without a look.
public struct PageFound: Equatable, Sendable {
    /// The corners in the photo's pixels, within the photo.
    public var corners: Quad
    /// The model was sure, the photo's edges back its outline and the page can be corrected. When false the corner
    /// editor starts from `corners`.
    public var clear: Bool

    public init(corners: Quad, clear: Bool) {
        self.corners = corners
        self.clear = clear
    }
}

/// Finds the page in a photo or a live frame with the corner model, and keeps the corners the editor moves usable.
public enum PageFinder {
    /// A page found with at least this confidence, and backed by the photo's edges, is cut out without asking.
    public static let sureConfidence = 0.7
    /// The model's page is taken from this confidence up (its weakest corner's peak).
    public static let minModelConfidence = 0.5
    /// The share of the weakest side the photo's edges must back (`QuadRefinement.support`) for a clear find.
    public static let minSureSupport = 0.7
    /// With nothing found, the editor starts with a rectangle this share of the photo in from each edge.
    public static let startInset = 0.1
    /// Every edge of the corners is at least this many photo pixels long.
    public static let minEdgePixels = 16.0
    /// A page covers at least this share of the frame…
    static let minAreaShare = 0.1
    /// …and is at most this many times as long as wide.
    static let maxLongOverShort = 2.0

    /// The page in `photo` (upright). A page the model is sure of is moved onto the photo's edges; anything less
    /// gives the corner editor's start, a rectangle inset from the edges when the model found nothing.
    public static func find(_ photo: RgbaImage, model: CornerModel?) -> PageFound {
        let w = photo.width, h = photo.height
        let start = PageFound(corners: startCorners(width: w, height: h), clear: false)
        guard let model, let heat = model.heatmaps(CornerModelInput.make(photo)),
              let seen = CornerHeatmap.decode(heat.values, width: heat.width, height: heat.height),
              seen.confidence >= minModelConfidence else { return start }
        let candidate = QuadCandidate(quad: seen.quad.scaled(Double(w), Double(h)), confidence: seen.confidence)
        guard let outline = documentOutline(candidate, width: w, height: h), canUseCorners(outline) else { return start }
        let refinement = QuadRefiner.refine(photo, outline)
        let corners = clamped(refinement.quad, width: w, height: h)
        let clear = seen.confidence >= sureConfidence && refinement.support >= minSureSupport
            && PerspectiveCorrector.plan(corners, imageWidth: w, imageHeight: h) != nil
        return PageFound(corners: corners, clear: clear)
    }

    /// The model's page for a live frame of `width` x `height`, when it is sure enough and has a page's shape.
    public static func accepted(_ candidate: QuadCandidate, width: Int, height: Int) -> Quad? {
        guard candidate.confidence >= minModelConfidence,
              let outline = documentOutline(candidate, width: width, height: height) else { return nil }
        let inside = clamped(outline, width: width, height: height)
        return canUseCorners(inside) ? inside : nil
    }

    /// The model's page in a live `frame` as the sensor gives it, turned upright by `turn` degrees (a multiple of 90) for the
    /// model, which was trained on pages the right way up, and back into the frame's own pixels. Nil when the model
    /// found no page.
    public static func frameCandidate(_ frame: RgbaImage, turn: Int, model: CornerModel) -> QuadCandidate? {
        let upright = frame.rotatedQuarterTurns(turn / 90)
        guard let heat = model.heatmaps(CornerModelInput.make(upright)),
              let seen = CornerHeatmap.decode(heat.values, width: heat.width, height: heat.height),
              let back = LiveQuadTracker.photoOutline(seen.quad, rotationDegrees: (360 - turn) % 360) else { return nil }
        return QuadCandidate(quad: back.scaled(Double(frame.width), Double(frame.height)), confidence: seen.confidence)
    }

    /// The candidate named by `Quad.fromCorners` when it is convex and a page's size and shape.
    static func documentOutline(_ candidate: QuadCandidate, width: Int, height: Int) -> Quad? {
        guard width > 0, height > 0 else { return nil }
        let quad = Quad.fromCorners(candidate.quad.corners)
        guard quad.isConvex else { return nil }
        let share = quad.area / (Double(width) * Double(height))
        guard share >= minAreaShare, share <= 1 else { return nil }
        let shape = PerspectiveCorrector.estimateAspect(quad, imageWidth: Double(width), imageHeight: Double(height)).longOverShort
        return shape >= 1 && shape <= maxLongOverShort ? quad : nil
    }

    /// The corners of the whole photo.
    public static func wholePhoto(width: Int, height: Int) -> Quad {
        let w = Double(width), h = Double(height)
        return Quad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: w, y: 0),
                    bottomRight: CGPoint(x: w, y: h), bottomLeft: CGPoint(x: 0, y: h))
    }

    /// A rectangle `startInset` of the photo in from each edge.
    public static func startCorners(width: Int, height: Int) -> Quad {
        let w = Double(width), h = Double(height)
        let dx = w * startInset, dy = h * startInset
        return Quad(topLeft: CGPoint(x: dx, y: dy), topRight: CGPoint(x: w - dx, y: dy),
                    bottomRight: CGPoint(x: w - dx, y: h - dy), bottomLeft: CGPoint(x: dx, y: h - dy))
    }

    /// `quad` with every corner moved into the photo; `startCorners` when that leaves no usable outline.
    public static func clamped(_ quad: Quad, width: Int, height: Int) -> Quad {
        let c = quad.corners.map { clamp($0, width: Double(width), height: Double(height)) }
        let inside = Quad(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3])
        return canUseCorners(inside) ? inside : startCorners(width: width, height: height)
    }

    /// Corners a page can be cut out along: a convex outline, every edge at least `minEdgePixels` long.
    public static func canUseCorners(_ quad: Quad) -> Bool {
        guard quad.isConvex else { return false }
        for i in 0..<4 where !(quad.edgeLength(i) >= minEdgePixels) {
            return false
        }
        return true
    }

    /// `quad` with corner `index` (0 top left, then clockwise) moved to `to`, kept within the photo; the quad as it
    /// was when the move would leave corners the page cannot be cut out along.
    public static func movedCorner(_ quad: Quad, index: Int, to: CGPoint, width: Int, height: Int) -> Quad {
        var corners = quad.corners
        corners[index & 3] = clamp(to, width: Double(width), height: Double(height))
        let moved = Quad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
        return canUseCorners(moved) ? moved : quad
    }

    private static func clamp(_ p: CGPoint, width: Double, height: Double) -> CGPoint {
        CGPoint(x: min(max(Double(p.x), 0), width), y: min(max(Double(p.y), 0), height))
    }
}
