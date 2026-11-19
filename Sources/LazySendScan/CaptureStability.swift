import CoreGraphics
import Foundation

/// Where the camera's automatic shutter stands (`CaptureStability`).
public enum CaptureState: Sendable {
    /// No page is seen clearly enough.
    case noPage
    /// A page is seen but moves.
    case moving
    /// The page holds still; the shutter fires when it has for long enough.
    case steadying
    /// The page was taken; waiting for it to go or move before the next.
    case captured
}

/// One video frame's detection, as the stability logic reads it.
public struct CaptureObservation: Equatable, Sendable {
    /// The page found in the frame, in the frame's pixels; nil when none.
    public var quad: Quad?
    /// The detection's confidence, 0...1.
    public var confidence: Double
    /// When the frame was taken, in milliseconds on any steady clock.
    public var timestampMs: Double
    /// The frame's size in pixels (movement is measured against its diagonal).
    public var frameWidth: Int
    public var frameHeight: Int
    /// How sharp the frame is (`FrameQuality`: the variance of the Laplacian); nil when not measured.
    public var sharpness: Double?
    /// How bright the frame is (`FrameQuality`: its mean luma, 0...255); nil when not measured.
    public var brightness: Double?

    public init(quad: Quad?, confidence: Double, timestampMs: Double, frameWidth: Int, frameHeight: Int,
                sharpness: Double? = nil, brightness: Double? = nil) {
        self.quad = quad
        self.confidence = confidence
        self.timestampMs = timestampMs
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.sharpness = sharpness
        self.brightness = brightness
    }
}

/// Whether a frame is good enough to be taken (`CaptureStability.judge`).
public enum CaptureQuality: Sendable {
    /// Sharp and lit, or not measured.
    case good
    /// Not sharp enough: the camera moves or has not focused yet.
    case blurry
    /// Too dark.
    case dark
}

/// Whether the page found fits the frame well (`CaptureStability.placement`).
public enum CapturePlacement: Sendable {
    /// Large enough and whole in the frame.
    case fine
    /// Covers too little of the frame to be read well.
    case far
    /// A corner lies on the frame's edge: part of the page is probably outside.
    case cutOff
}

/// What the shutter should do after a frame.
public struct CaptureDecision: Equatable, Sendable {
    /// The state after the frame.
    public var state: CaptureState
    /// Take the photo now (true on exactly one frame per steady page).
    public var shouldCapture: Bool
    /// How far the page is through the steady time, 0...1 (for a ring in the view).
    public var progress: Double
    /// The frame's quality (`CaptureStability.judge`); a page held still long enough waits while it is not good.
    public var quality: CaptureQuality = .good
    /// A page held still has waited `CaptureStability.softHintMs` for a sharp frame: tapping the shutter may do better.
    public var suggestsShutter = false
}

/// The thresholds of `CaptureStability`; the defaults are its constants.
public struct CaptureStabilityOptions: Equatable, Sendable {
    /// The page must hold still this long before the shutter fires.
    public var steadyMs = CaptureStability.steadyMs
    /// To start holding still, no corner moved more than this share of the frame's diagonal since the last frame.
    public var enterMovement = CaptureStability.enterMovement
    /// While holding still, no corner strays more than this share from where it was when holding started.
    public var stayMovement = CaptureStability.stayMovement
    /// To start holding still the detection must be at least this confident…
    public var enterConfidence = CaptureStability.enterConfidence
    /// …and to stay, at least this.
    public var stayConfidence = CaptureStability.stayConfidence
    /// A page missing from the frames for up to this long is still the same page.
    public var maxGapMs = CaptureStability.maxGapMs
    /// After a capture, the next page counts as new once a corner moved this share of the diagonal from the captured page.
    public var newPageMovement = CaptureStability.newPageMovement
    /// A frame less sharp than this (`CaptureObservation.sharpness`) is not taken.
    public var minSharpness = CaptureStability.minSharpness
    /// A frame darker than this (`CaptureObservation.brightness`) is not taken.
    public var minBrightness = CaptureStability.minBrightness

    public init() {}

    public static let `default` = CaptureStabilityOptions()
}

/// Decides when the camera may take the page by itself: the page must be seen with confidence for
/// `steadyMs` with its corners holding still. Hysteresis keeps the decision from flickering: holding
/// still starts when no corner moved more than `enterMovement` of the diagonal since the previous
/// frame with confidence at least `enterConfidence`, and lasts while no corner strays more than
/// `stayMovement` from where it was then and the confidence stays at least `stayConfidence`; a page
/// missing for up to `maxGapMs` is waited for, and the time it was missing does not count as holding
/// still. Once taken, the same page is not taken again: the shutter re-arms when frames without a
/// page span more than `maxGapMs` (the page has gone) or a corner moved `newPageMovement` from where
/// it was taken, or when `reset()` is called; a pause between frames alone does not re-arm it, and after
/// the camera stopped for a while `resume(atMs:)` takes the time without frames out, so it counts neither
/// as time the page was missing nor as time it held still. A page held still long enough is taken only from a frame that is sharp and lit (`judge`, when the frame's
/// `sharpness` and `brightness` were measured): until one comes, the page stays steadying with its
/// progress full, and every decision says how the frame was judged (`CaptureDecision.quality`).
/// `markCaptured()` counts the page in view as taken (a photo taken by hand). Corners are compared
/// whichever of them a quad names first (`movement`), so a page turned to where `Quad.fromCorners`
/// names its corners from another edge does not seem to move. Pure logic: the
/// camera feeds it one `CaptureObservation` per analysed frame, in time order.
public struct CaptureStability: Sendable {
    public static let steadyMs = 600.0
    public static let enterMovement = 0.01
    public static let stayMovement = 0.025
    public static let enterConfidence = 0.6
    public static let stayConfidence = 0.45
    public static let maxGapMs = 250.0
    public static let newPageMovement = 0.15
    /// The least sharpness a frame is taken at: the variance of its luma's 4-neighbour Laplacian (`FrameQuality`).
    public static let minSharpness = 40.0
    /// The least brightness a frame is taken at: its mean luma, 0...255 (`FrameQuality`).
    public static let minBrightness = 50.0
    /// A page covering less than this share of the frame's area is too far away.
    public static let minAreaShare = 0.2
    /// A corner closer than this share of the frame's diagonal to the frame's edge counts as on it.
    public static let edgeMargin = 0.01
    /// A page held still and blurred for this long suggests tapping the shutter.
    public static let softHintMs = 2000.0
    /// The automatic shutter takes no photo for this long after the camera goes live (launch, back from the background, a sheet closed).
    public static let autoGraceMs = 1500.0

    private let options: CaptureStabilityOptions
    private var previous: Quad?
    private var anchor: Quad?
    private var captured: Quad?
    private var steadySince = 0.0
    private var lastSeen = -Double.infinity
    private var lastFrame = -Double.infinity
    private var missing = false
    private var softSince: Double?

    /// The state after the last frame.
    public private(set) var state: CaptureState = .noPage

    public init(options: CaptureStabilityOptions = .default) {
        self.options = options
    }

    /// Forget everything (a new document, the user took a photo by hand): the next steady page is taken.
    public mutating func reset() {
        state = .noPage
        previous = nil
        anchor = nil
        captured = nil
        lastSeen = -Double.infinity
        lastFrame = -Double.infinity
        missing = false
        softSince = nil
    }

    /// Frames come again after a pause (the camera stopped for a while and started again), the first of them
    /// taken at `timestampMs`: the time since the last frame counts neither as time the page was missing nor
    /// as time it held still, as if the first frame came right after the last. So a page taken before the
    /// pause stays taken through a first frame that misses it, and a page holding still goes on from where it
    /// was. Nothing changes before any frame, or for a time before the last frame's.
    public mutating func resume(atMs timestampMs: Double) {
        guard lastFrame != -Double.infinity, timestampMs > lastFrame else { return }
        let paused: Double = timestampMs - lastFrame
        lastFrame = timestampMs
        lastSeen += paused
        steadySince += paused
        softSince = softSince.map { $0 + paused }
    }

    /// The page in view was taken another way (the shutter pressed by hand): it counts as captured, so the
    /// same page is not taken again until it moves or goes. Nothing changes while no page is seen.
    public mutating func markCaptured() {
        guard let quad = previous else { return }
        state = .captured
        captured = quad
        anchor = nil
    }

    /// How a frame with these readings is judged: `.dark` below `minBrightness`, else `.blurry` below
    /// `minSharpness`, else (and when not measured) `.good`.
    public static func judge(sharpness: Double?, brightness: Double?,
                             options: CaptureStabilityOptions = .default) -> CaptureQuality {
        if let lit = brightness, lit < options.minBrightness { return .dark }
        if let sharp = sharpness, sharp < options.minSharpness { return .blurry }
        return .good
    }

    /// How `quad` sits in a frame of this size: `.cutOff` when a corner is within `edgeMargin` of the diagonal
    /// from the frame's edge, else `.far` below `minAreaShare` of the frame's area, else `.fine`.
    public static func placement(of quad: Quad, frameWidth: Int, frameHeight: Int) -> CapturePlacement {
        let w = Double(frameWidth), h = Double(frameHeight)
        let margin: Double = edgeMargin * (w * w + h * h).squareRoot()
        if !quad.isInside(width: w, height: h, margin: margin) { return .cutOff }
        if quad.area < minAreaShare * w * h { return .far }
        return .fine
    }

    /// The decision after one more frame.
    public mutating func update(_ frame: CaptureObservation) -> CaptureDecision {
        let quality: CaptureQuality = CaptureStability.judge(sharpness: frame.sharpness, brightness: frame.brightness,
                                                             options: options)
        lastFrame = frame.timestampMs
        var decision: CaptureDecision = decide(frame, quality: quality)
        decision.quality = quality
        return decision
    }

    private mutating func decide(_ frame: CaptureObservation, quality: CaptureQuality) -> CaptureDecision {
        let o = options
        let fw = Double(frame.frameWidth), fh = Double(frame.frameHeight)
        let diagonal = (fw * fw + fh * fh).squareRoot()
        let t = frame.timestampMs
        // Only a held, blurred page keeps the time; a short gap in the frames does not break it.
        let blurredSince = softSince
        softSince = nil

        guard let quad = frame.quad else {
            if t - lastSeen <= o.maxGapMs {
                softSince = blurredSince
                // Waiting for the page to come back; the steady time stands still meanwhile.
                missing = true
                return CaptureDecision(state: state, shouldCapture: false,
                                       progress: state == .steadying ? progress(lastSeen) : 0)
            }
            previous = nil
            anchor = nil
            captured = nil
            missing = false
            state = .noPage
            return CaptureDecision(state: state, shouldCapture: false, progress: 0)
        }

        let returning = t - lastSeen > o.maxGapMs
        // Back after frames without it: the time it was missing is not time held still.
        if missing && !returning { steadySince += t - lastSeen }
        missing = false
        lastSeen = t
        let last = previous
        previous = quad

        if state == .captured {
            // The page taken stays taken, however long since the last frame, until it moves away.
            if let taken = captured, CaptureStability.movement(quad, taken) < o.newPageMovement * diagonal {
                return CaptureDecision(state: state, shouldCapture: false, progress: 1)
            }
            captured = nil
            state = .moving
        }
        if returning {
            anchor = nil
            state = frame.confidence >= o.stayConfidence ? .moving : .noPage
            return CaptureDecision(state: state, shouldCapture: false, progress: 0)
        }

        if state == .steadying, let held = anchor {
            let stays = frame.confidence >= o.stayConfidence && CaptureStability.movement(quad, held) <= o.stayMovement * diagonal
            if stays {
                if t - steadySince >= o.steadyMs {
                    // Held still long enough: taken from the first frame that is sharp and lit.
                    if quality != .good {
                        var waiting = CaptureDecision(state: state, shouldCapture: false, progress: 1)
                        if quality == .blurry {
                            let since: Double = blurredSince ?? t
                            softSince = since
                            waiting.suggestsShutter = t - since >= CaptureStability.softHintMs
                        }
                        return waiting
                    }
                    state = .captured
                    captured = quad
                    anchor = nil
                    return CaptureDecision(state: state, shouldCapture: true, progress: 1)
                }
                return CaptureDecision(state: state, shouldCapture: false, progress: progress(t))
            }
            anchor = nil
            state = frame.confidence >= o.stayConfidence ? .moving : .noPage
            return CaptureDecision(state: state, shouldCapture: false, progress: 0)
        }

        if frame.confidence < o.enterConfidence {
            state = frame.confidence >= o.stayConfidence ? .moving : .noPage
            return CaptureDecision(state: state, shouldCapture: false, progress: 0)
        }
        if let earlier = last, CaptureStability.movement(quad, earlier) <= o.enterMovement * diagonal {
            state = .steadying
            anchor = earlier
            steadySince = t
            return CaptureDecision(state: state, shouldCapture: false, progress: 0)
        }
        state = .moving
        return CaptureDecision(state: state, shouldCapture: false, progress: 0)
    }

    private func progress(_ t: Double) -> Double {
        min(max((t - steadySince) / options.steadyMs, 0), 1)
    }

    /// How far the page moved from `b` to `a`: the largest distance between their corners, paired from
    /// whichever corner of `b` fits best (the least over the four ways round), so a quad whose corners
    /// are named from another edge is the same.
    public static func movement(_ a: Quad, _ b: Quad) -> Double {
        var best = Double.greatestFiniteMagnitude
        for shift in 0..<4 {
            var worst = 0.0
            for i in 0..<4 { worst = max(worst, Quad.distance(a[i], b[i + shift])) }
            best = min(best, worst)
        }
        return best
    }
}
