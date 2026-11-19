import CoreGraphics
import Foundation

/// Steadies the page found in successive live frames (pixels of one frame size) before it is drawn and
/// judged. A corner that moved at most `jitterShare` of the frame's diagonal since the outline before is
/// moved only `smoothing` of the way (the outline stops trembling); one that moved further is followed
/// at once, so a page slid across the table is not drawn behind it. A page that jumped more than
/// `jumpShare` (a corner of it) is not believed on one frame: it is passed over (no page that frame)
/// unless the next frame finds it away from the outline too, there or further on (a page moved fast), when
/// it is the page from then on; while it keeps jumping, each frame is followed. A page seen for the first
/// time is not drawn until it is found again on the next frame (one missing in between forgets it); a page
/// drawn and then missed keeps its outline for `LiveQuadTracker.holdMs` after it was last found. Corners
/// are paired with the outline before whichever corner the search named first, as `CaptureStability`
/// compares them. Pure logic, one frame after another in time order.
public struct LiveQuadFilter: Sendable {
    /// How far a trembling corner moves toward where it was found.
    public static let smoothing: Double = 0.5
    /// A corner moving at most this share of the diagonal trembles; further, it moves.
    public static let jitterShare: Double = 0.01
    /// A page whose corner jumped more than this share of the diagonal is believed on its second sighting.
    public static let jumpShare: Double = 0.06

    /// What one frame gives: the steadied page for the shutter's judgement (nil when none was found, or a
    /// jump was passed over), and the outline to draw (nil when there is none to draw).
    public struct Output: Equatable, Sendable {
        public let page: Quad?
        public let shown: Quad?
    }

    private var current: Quad?
    private var drawn: Bool = false
    private var jumped: Quad?
    private var seenMs: Double = -Double.infinity

    public init() {}

    /// The frame taken at `t` ms, where the page search found `found` (nil: no page), in a frame whose
    /// diagonal is `diagonal` px.
    public mutating func update(_ found: Quad?, atMs t: Double, diagonal: Double) -> Output {
        if current != nil && (t - seenMs > LiveQuadTracker.holdMs || t < seenMs) {
            current = nil
            drawn = false
            jumped = nil
        }
        guard let quad = found else {
            jumped = nil
            if !drawn {
                current = nil
            }
            return Output(page: nil, shown: drawn ? current : nil)
        }
        guard let before = current else {
            current = quad
            seenMs = t
            return Output(page: quad, shown: nil)
        }
        let aligned: Quad = LiveQuadFilter.aligned(quad, to: before)
        let limit: Double = LiveQuadFilter.jumpShare * diagonal
        if aligned.maxCornerDistance(before) > limit {
            if !drawn {
                current = quad
                seenMs = t
                return Output(page: quad, shown: nil)
            }
            if jumped != nil {
                current = quad
                jumped = quad
                seenMs = t
                return Output(page: quad, shown: quad)
            }
            jumped = quad
            return Output(page: nil, shown: before)
        }
        let steadied: Quad = LiveQuadFilter.blended(before, aligned, jitter: LiveQuadFilter.jitterShare * diagonal)
        current = steadied
        drawn = true
        jumped = nil
        seenMs = t
        return Output(page: steadied, shown: steadied)
    }

    /// `quad`'s corners renamed to pair with `reference`'s: shifted round by whichever of the four ways
    /// brings the farthest pair nearest.
    static func aligned(_ quad: Quad, to reference: Quad) -> Quad {
        var bestShift: Int = 0
        var best: Double = Double.greatestFiniteMagnitude
        var shift: Int = 0
        while shift < 4 {
            var worst: Double = 0
            var index: Int = 0
            while index < 4 {
                let a: CGPoint = quad[index + shift]
                let b: CGPoint = reference[index]
                let dx: Double = Double(a.x) - Double(b.x)
                let dy: Double = Double(a.y) - Double(b.y)
                worst = max(worst, (dx * dx + dy * dy).squareRoot())
                index += 1
            }
            if worst < best {
                best = worst
                bestShift = shift
            }
            shift += 1
        }
        return Quad(topLeft: quad[bestShift], topRight: quad[bestShift + 1], bottomRight: quad[bestShift + 2],
                    bottomLeft: quad[bestShift + 3])
    }

    /// Each corner of `before` moved `smoothing` of the way to `found`'s when within `jitter` px of it,
    /// else all the way.
    static func blended(_ before: Quad, _ found: Quad, jitter: Double) -> Quad {
        var corners: [CGPoint] = []
        var index: Int = 0
        while index < 4 {
            let a: CGPoint = before[index]
            let b: CGPoint = found[index]
            let dx: Double = Double(b.x) - Double(a.x)
            let dy: Double = Double(b.y) - Double(a.y)
            if (dx * dx + dy * dy).squareRoot() <= jitter {
                corners.append(CGPoint(x: Double(a.x) + LiveQuadFilter.smoothing * dx,
                                       y: Double(a.y) + LiveQuadFilter.smoothing * dy))
            } else {
                corners.append(b)
            }
            index += 1
        }
        return Quad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
    }
}
