import CoreGraphics
import Foundation

/// One live frame of the camera, made small for the page search: its pixels as the sensor gives them (not turned for
/// the screen), when it was taken in milliseconds of the capture clock, and the page the corner model found in it
/// (`PageFinder.frameCandidate`, in `image`'s pixels), nil when the model found none or did not run.
public struct ScanFrame: Sendable {
    public let image: RgbaImage
    public let timestampMs: Double
    public let page: QuadCandidate?

    public init(image: RgbaImage, timestampMs: Double, page: QuadCandidate? = nil) {
        self.image = image
        self.timestampMs = timestampMs
        self.page = page
    }
}

/// What the tracker saw in a frame: the page's outline (corners as shares of the frame, 0...1, x to the right and y
/// down, named by `Quad.fromCorners`), nil when no page is in view; how steady it is (`CaptureStability`); whether it
/// holds still now; the frame's time; and the shutter's decision: take the photo now (`shouldCapture`, once per page
/// held still on a sharp, lit frame), how the frame was judged (`quality`), how the page sits in the frame
/// (`placement`) and whether a blurred page has waited long enough to suggest the shutter (`suggestsShutter`).
public struct LiveQuadUpdate: Equatable, Sendable {
    public let outline: Quad?
    public let state: CaptureState
    public let progress: Double
    public let timestampMs: Double
    /// The page holds still now (the outline is drawn green): `.steadying`, or `.captured` while the page stays where
    /// it held still, not merely within `newPageMovement` of it. For the outline's colour only: the automatic
    /// shutter follows `shouldCapture`.
    public let isSteady: Bool
    public let shouldCapture: Bool
    public let quality: CaptureQuality
    public let placement: CapturePlacement
    public let suggestsShutter: Bool

    public init(outline: Quad?, state: CaptureState, progress: Double, timestampMs: Double, isSteady: Bool? = nil,
                shouldCapture: Bool = false, quality: CaptureQuality = .good, placement: CapturePlacement = .fine,
                suggestsShutter: Bool = false) {
        self.outline = outline
        self.state = state
        self.progress = progress
        self.timestampMs = timestampMs
        self.isSteady = isSteady ?? (state == .steadying)
        self.shouldCapture = shouldCapture
        self.quality = quality
        self.placement = placement
        self.suggestsShutter = suggestsShutter
    }
}

/// Follows the page in the camera's live frames for the outline drawn over the preview. About ten frames a second are
/// looked at (`minFrameGapMs`; the others are passed over before any work): the page the corner model found in the
/// frame when it is a page's (`PageFinder.accepted`) and sure enough to start holding still
/// (`CaptureStability.enterConfidence`, at least). What is found is steadied (`LiveQuadFilter`): small jitter is
/// smoothed, a jump is believed only once it is seen twice, a new page is drawn from its second sighting and a page
/// missed for a moment keeps its outline for `holdMs`; how steady the steadied page is comes from `CaptureStability`.
/// Once `CaptureStability` has taken the page (`.captured`) it keeps that state until the page moves `newPageMovement`
/// away, so whether the page holds still meanwhile is judged here, by the same rules. Each frame is also measured
/// (`FrameQuality`, over the page found: how sharp, how bright), so the shutter's decision comes only from a page held
/// still on a sharp, lit frame. A photo taken (`markCaptured()`) counts the page in view as taken, so the next is
/// taken only once the page moved away or went; a pause (`pause()`: the camera stopped for the corner editor, the
/// background) keeps that, and the time the camera was stopped counts neither as time the page was missing nor as
/// time it held still. A page held still again after it went or was covered is not decided on when it looks like the
/// page last photographed (`PageThumbnail`), so a shake or a hand over the page does not take it twice. Frames are
/// handled one at a time on the caller's queue; `reset()` may be called from any thread and drops a frame being
/// handled meanwhile.
public final class LiveQuadTracker: @unchecked Sendable {
    /// A frame this soon after the last one handled is passed over (a 30 fps camera's every third frame is used).
    public static let minFrameGapMs: Double = 90
    /// The same while the phone is warm, which the frame feed uses to pass frames over: about four a second.
    public static let warmFrameGapMs: Double = 225
    /// The long side live frames are searched at.
    public static let analysisLongSide: Int = 480
    /// A page missed for at most this long keeps its outline.
    public static let holdMs: Double = 300

    public typealias QualityMeasure = @Sendable (RgbaImage, Quad?) -> FrameQualityReading

    private let measure: QualityMeasure
    private let stabilityOptions: CaptureStabilityOptions
    private let lock = NSLock()
    private var stability: CaptureStability
    private var lastHandledMs: Double?
    private var filter = LiveQuadFilter()
    private var lastFound: Quad?
    /// Where the page held still while `.captured` (pixels); nil while it does not.
    private var heldAt: Quad?
    private var frameWidth: Int = 0
    private var frameHeight: Int = 0
    private var generation: Int = 0
    /// The first frame after a pause resumes `stability` first.
    private var resuming: Bool = false
    /// A photo was taken of the page `stability` counts as taken (`markCaptured()`), not only decided on.
    private var photographed: Bool = false
    private var latestImage: RgbaImage?
    private var photographedLook: PageThumbnail?

    /// `quality` nil: `FrameQuality.measure`.
    public init(stability: CaptureStabilityOptions = .default, quality: QualityMeasure? = nil) {
        self.measure = quality ?? { (image: RgbaImage, page: Quad?) -> FrameQualityReading in
            FrameQuality.measure(image, region: page)
        }
        self.stabilityOptions = stability
        self.stability = CaptureStability(options: stability)
    }

    /// Handles `frame` unless it comes too soon after the last one (nil then). A frame from an earlier time than the
    /// last one (the camera started again) or of another size starts over.
    public func process(_ frame: ScanFrame) -> LiveQuadUpdate? {
        let t: Double = frame.timestampMs
        let width: Int = frame.image.width
        let height: Int = frame.image.height
        lock.lock()
        let gap: Double = LiveQuadTracker.minFrameGapMs
        if let last = lastHandledMs {
            if t < last {
                clearState()
            } else if t - last < gap {
                lock.unlock()
                return nil
            }
        }
        if width != frameWidth || height != frameHeight {
            clearState()
            frameWidth = width
            frameHeight = height
        }
        lastHandledMs = t
        let started: Int = generation
        lock.unlock()

        // A page the model is less sure of than holding still needs would never be taken.
        let floor: Double = max(PageFinder.minModelConfidence, stabilityOptions.enterConfidence)
        var found: Quad?
        var confidence: Double = 0
        if let page = frame.page, page.confidence >= floor,
           let quad = PageFinder.accepted(page, width: width, height: height) {
            found = quad
            confidence = page.confidence
        }
        let reading: FrameQualityReading = measure(frame.image, found)

        lock.lock()
        defer { lock.unlock() }
        // Reset while the frame was handled: its answer belongs to before.
        guard started == generation else { return nil }
        if resuming {
            resuming = false
            stability.resume(atMs: t)
        }
        let diagonal: Double = (Double(width) * Double(width) + Double(height) * Double(height)).squareRoot()
        let steadied: LiveQuadFilter.Output = filter.update(found, atMs: t, diagonal: diagonal)
        let observation = CaptureObservation(quad: steadied.page, confidence: confidence, timestampMs: t,
                                             frameWidth: width, frameHeight: height,
                                             sharpness: reading.sharpness, brightness: reading.brightness)
        var decision: CaptureDecision = stability.update(observation)
        latestImage = frame.image
        // The page came back after a shake or a hand over it and held still: it is the page already taken.
        if decision.shouldCapture, let look = photographedLook, let page = steadied.page,
           PageThumbnail(frame.image, page: page).matches(look) {
            decision.shouldCapture = false
            photographed = true
        }
        if decision.state != .captured {
            photographed = false
        }
        let steady: Bool = holdsStill(decision, quad: steadied.page, confidence: confidence, diagonal: diagonal)
        lastFound = steadied.page
        var outline: Quad?
        if let quad = steadied.shown {
            outline = LiveQuadTracker.normalized(quad, width: width, height: height)
        }
        var placement: CapturePlacement = .fine
        if let page = steadied.page {
            placement = CaptureStability.placement(of: page, frameWidth: width, frameHeight: height)
        }
        return LiveQuadUpdate(outline: outline, state: decision.state, progress: decision.progress, timestampMs: t,
                              isSteady: steady, shouldCapture: decision.shouldCapture, quality: decision.quality,
                              placement: placement, suggestsShutter: decision.suggestsShutter)
    }

    /// Whether the page holds still after `decision` (called with the lock held): while `.steadying`, yes; while
    /// `.captured`, as long as no corner strays `stayMovement` of the `diagonal` from where it held still, and again
    /// once no corner moved `enterMovement` since the frame before (with the confidences `CaptureStability` asks
    /// for); a page missed for a moment holds still as it did. Otherwise, no.
    private func holdsStill(_ decision: CaptureDecision, quad: Quad?, confidence: Double, diagonal: Double) -> Bool {
        let o: CaptureStabilityOptions = stabilityOptions
        switch decision.state {
        case .steadying:
            heldAt = nil
            return true
        case .noPage, .moving:
            heldAt = nil
            return false
        case .captured:
            guard let found = quad else {
                return heldAt != nil
            }
            if decision.shouldCapture {
                heldAt = found
                return true
            }
            if let held = heldAt, confidence >= o.stayConfidence,
               CaptureStability.movement(found, held) <= o.stayMovement * diagonal {
                return true
            }
            if let earlier = lastFound, confidence >= o.enterConfidence,
               CaptureStability.movement(found, earlier) <= o.enterMovement * diagonal {
                heldAt = earlier
                return true
            }
            heldAt = nil
            return false
        }
    }

    /// Judges the page afresh: how steady it is and whether it was taken start over with the next frame. The outline
    /// drawn stays, so it does not blink; once frames stop coming for longer than `holdMs` it goes by itself.
    public func reset() {
        lock.lock()
        clearJudgement()
        generation += 1
        lock.unlock()
    }

    /// A photo was taken of the page in view (by hand, or as the shutter's decision said): it counts as taken
    /// (`CaptureStability.markCaptured`), so it is not taken again until it moves away or goes.
    public func markCaptured() {
        lock.lock()
        stability.markCaptured()
        if stability.state == .captured {
            heldAt = lastFound
            photographed = true
            photographedLook = nil
            if let image = latestImage, let page = lastFound {
                photographedLook = PageThumbnail(image, page: page)
            }
        }
        lock.unlock()
    }

    /// The automatic shutter was turned on, or a photo can be taken again: a page `CaptureStability` counted as taken
    /// while no photo was taken of it is judged afresh, so it is taken once it holds still; a page photographed stays
    /// taken, and nothing else changes.
    public func rearm() {
        lock.lock()
        let untaken: Bool = stability.state == .captured && !photographed
        lock.unlock()
        if untaken {
            reset()
        }
    }

    /// The camera stops for a while (the corner editor, the background): what is known of the page is kept, above all
    /// that it was taken, and the time until the next frame counts neither as time the page was missing nor as time it
    /// held still.
    public func pause() {
        lock.lock()
        resuming = true
        lock.unlock()
    }

    /// `quad` (pixels of a `width` x `height` frame) as shares of the frame.
    public static func normalized(_ quad: Quad, width: Int, height: Int) -> Quad {
        let sx: Double = 1.0 / Double(max(width, 1))
        let sy: Double = 1.0 / Double(max(height, 1))
        return quad.scaled(sx, sy)
    }

    /// A live outline (shares of the sensor's frame, as the frames come) in the photo taken with the turn
    /// `rotationDegrees` (clockwise; 0, 90, 180 or 270, the capture's rotation angle), as shares of that photo once
    /// it is upright; nil for any other turn.
    public static func photoOutline(_ outline: Quad, rotationDegrees: Int) -> Quad? {
        let turn: Int = ((rotationDegrees % 360) + 360) % 360
        guard turn % 90 == 0 else { return nil }
        let quarters: Int = turn / 90
        var points: [CGPoint] = []
        for corner in outline.corners {
            let x: Double = Double(corner.x)
            let y: Double = Double(corner.y)
            switch quarters {
            case 1: points.append(CGPoint(x: 1.0 - y, y: x))
            case 2: points.append(CGPoint(x: 1.0 - x, y: 1.0 - y))
            case 3: points.append(CGPoint(x: y, y: 1.0 - x))
            default: points.append(CGPoint(x: x, y: y))
            }
        }
        return Quad.fromCorners(points)
    }

    /// Forgets everything (frames of another size, a clock that started over). Called with the lock held.
    private func clearState() {
        clearJudgement()
        filter = LiveQuadFilter()
    }

    /// Forgets how steady the page was and whether it was taken. Called with the lock held.
    private func clearJudgement() {
        stability = CaptureStability(options: stabilityOptions)
        lastHandledMs = nil
        lastFound = nil
        heldAt = nil
        resuming = false
        photographed = false
        photographedLook = nil
    }
}
