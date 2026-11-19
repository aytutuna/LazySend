#if os(iOS)
import AVFoundation
import LazySendScan

/// The camera's live frames for the page outline: each BGRA frame of the video output is made small (`FrameScaler`),
/// searched whole by the corner model (`PageFinder.frameCandidate`) and handed on from a queue of its own, so a model
/// run never holds up the frames behind it. Frames that come sooner than the tracker wants one after the last handed
/// over are passed over before any work, and so are frames that come while one is still being worked on; the small copy
/// is all that is kept, never the camera's buffer. The model sees the frame turned upright and the tracker the frame as
/// the sensor gives it, since the outline is drawn in the sensor's frame.
final class ScanFrameFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let work = DispatchQueue(label: "LazySend.scan.track", qos: .userInitiated)
    private let model: CornerModel?
    private var deliver: (@Sendable (ScanFrame) -> Void)?
    private var lastMs: Double?
    private var working = false
    /// A phone held upright shows the back camera's frames turned a quarter clockwise.
    private var turn = 90

    /// `model` nil: frames still go on, with no page found in them.
    init(model: CornerModel?) {
        self.model = model
    }

    func start(_ deliver: @escaping @Sendable (ScanFrame) -> Void) {
        lock.lock()
        self.deliver = deliver
        lastMs = nil
        lock.unlock()
    }

    func stop() {
        lock.lock()
        deliver = nil
        lock.unlock()
    }

    /// The preview's turn (clockwise degrees, a multiple of 90) that shows the sensor's frames upright.
    func setUprightTurn(_ angle: CGFloat) {
        let quarters = Int((Double(angle) / 90).rounded())
        lock.lock()
        turn = ((quarters % 4 + 4) % 4) * 90
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard seconds.isFinite, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ms = seconds * 1000
        lock.lock()
        let handler = deliver
        let warm = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.fair.rawValue
        let gap = warm ? LiveQuadTracker.warmFrameGapMs : LiveQuadTracker.minFrameGapMs
        var due = handler != nil && !working
        if let last = lastMs, ms >= last, ms - last < gap { due = false }
        lock.unlock()
        guard due, let send = handler, let image = ScanFrameFeed.image(pixels) else { return }
        lock.lock()
        lastMs = ms
        working = true
        let upright = turn
        lock.unlock()
        work.async {
            let page = self.model.flatMap { PageFinder.frameCandidate(image, turn: upright, model: $0) }
            send(ScanFrame(image: image, timestampMs: ms, page: page))
            self.lock.lock()
            self.working = false
            self.lock.unlock()
        }
    }

    /// The frame's pixels made small; nil when it is not a BGRA frame.
    static func image(_ pixelBuffer: CVPixelBuffer) -> RgbaImage? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(base), count: bytesPerRow * height)
        return FrameScaler.downscaled(bgra: bytes, width: width, height: height, bytesPerRow: bytesPerRow,
                                      maxLongSide: LiveQuadTracker.analysisLongSide)
    }
}
#endif
