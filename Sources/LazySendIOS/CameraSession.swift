#if os(iOS)
import AVFoundation
import CoreMedia
import CoreVideo

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Data?) -> Void
    private var data: Data?
    private var finished = false

    init(completion: @escaping @Sendable (Data?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error == nil { data = photo.fileDataRepresentation() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard !finished else { return }
        finished = true
        completion(data)
    }
}

/// What a camera offers once it is the session's input.
struct CameraSetup {
    var device: AVCaptureDevice
    var base: Double
    var lowest: Double
    /// The zoom factor where the telephoto lens takes over, on a phone that has one.
    var telephoto: Double?
    var highest: Double
    var flash: Bool
    var torch: Bool
}

/// The capture session and its photo output. Every method runs on `queue`, so the session is set up, started and
/// stopped off the main thread.
final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "LazySend.camera")
    private let output = AVCapturePhotoOutput()
    // The live frames of scan mode, which are only in the session while that mode is in front.
    private let frameOutput = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "LazySend.camera.frames", qos: .userInitiated)
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var pending: [Int64: PhotoDelegate] = [:]

    /// Points the session at the camera facing `position`; nil when there is none or it cannot be used.
    func use(_ position: AVCaptureDevice.Position) -> CameraSetup? {
        guard let camera = CameraLens.best(position), let next = try? AVCaptureDeviceInput(device: camera) else { return nil }
        session.beginConfiguration()
        if let old = input { session.removeInput(old) }
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        guard session.canAddInput(next) else {
            if let old = input, session.canAddInput(old) { session.addInput(old) }
            session.commitConfiguration()
            return nil
        }
        session.addInput(next)
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else {
                session.removeInput(next)
                session.commitConfiguration()
                return nil
            }
            session.addOutput(output)
        }
        session.commitConfiguration()
        input = next
        device = camera
        if scanning {
            // The new camera starts on the photo preset: the outline format is chosen again for it.
            scanning = false
            session.beginConfiguration()
            useOutlineFormat()
            session.commitConfiguration()
        }
        let base = CameraLens.startZoom(camera)
        let switchOvers = camera.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
        let kind = CameraLens.kind(camera.deviceType)
        var telephoto: Double?
        if kind == .triple, switchOvers.count >= 2 {
            telephoto = switchOvers[1]
        } else if kind == .dual {
            telephoto = switchOvers.first
        }
        setZoom(base)
        return CameraSetup(device: camera, base: base, lowest: Double(camera.minAvailableVideoZoomFactor), telephoto: telephoto, highest: min(Double(camera.maxAvailableVideoZoomFactor), base * 10),
                           flash: output.supportedFlashModes.contains(.on), torch: camera.hasTorch)
    }

    /// Hands the camera's frames to `delegate` (BGRA), or takes the output out of the session with nil. Once added the output
    /// stays while scan mode is in front; the owner stops delivering instead of removing it. While it is there the camera
    /// runs a smaller video format that still takes 12 megapixel photos (`outlineFormat`), as Lazy Scan does, since the
    /// photo preset's frames are 12 megapixels and heat the phone for an outline that is read at 480 pixels.
    func setFrames(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate?) {
        session.beginConfiguration()
        if let delegate {
            frameOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)]
            frameOutput.alwaysDiscardsLateVideoFrames = true
            frameOutput.setSampleBufferDelegate(delegate, queue: frameQueue)
            if !session.outputs.contains(frameOutput), session.canAddOutput(frameOutput) { session.addOutput(frameOutput) }
            // The frames are as the sensor gives them: the outline is drawn in the sensor's frame.
            if let connection = frameOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
                if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
            }
            useOutlineFormat()
        } else {
            frameOutput.setSampleBufferDelegate(nil, queue: nil)
            if session.outputs.contains(frameOutput) { session.removeOutput(frameOutput) }
            usePhotoFormat()
        }
        session.commitConfiguration()
        if let camera = device { setZoom(CameraLens.startZoom(camera)) }
    }

    /// The photo size scan mode takes: 12 megapixels, which a page needs no more than.
    private static let scanPhoto = CMVideoDimensions(width: 4032, height: 3024)
    private var scanning = false
    private var photoDimensions: CMVideoDimensions?

    /// The smallest standard 4:3 video format (full-range 4:2:0, not binned, 30 fps, at least 1920 x 1440 so the preview is not
    /// enlarged) that takes the 12 megapixel photos at the best quality; the session keeps the photo preset's format when the
    /// camera has none, and the frames are then full size.
    private func useOutlineFormat() {
        guard let camera = device, !scanning else { return }
        let photo = CameraSession.scanPhoto
        var best: AVCaptureDevice.Format?
        var bestWidth: Int32 = 0
        for format in camera.formats {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard size.width * 3 == size.height * 4, size.width >= 1920, size.width < photo.width,
                  CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                  !format.isVideoBinned, format.isHighPhotoQualitySupported,
                  format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }),
                  format.supportedMaxPhotoDimensions.contains(where: { $0.width == photo.width && $0.height == photo.height })
            else { continue }
            if best == nil || size.width < bestWidth {
                best = format
                bestWidth = size.width
            }
        }
        guard let chosen = best, chosen != camera.activeFormat, session.canSetSessionPreset(.inputPriority),
              (try? camera.lockForConfiguration()) != nil else { return }
        session.sessionPreset = .inputPriority
        camera.activeFormat = chosen
        camera.unlockForConfiguration()
        if photoDimensions == nil { photoDimensions = output.maxPhotoDimensions }
        output.maxPhotoDimensions = photo
        output.maxPhotoQualityPrioritization = .quality
        scanning = true
    }

    /// Back to the photo preset, which brings its own format and photo size.
    private func usePhotoFormat() {
        guard scanning else { return }
        scanning = false
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        if let before = photoDimensions { output.maxPhotoDimensions = before }
        photoDimensions = nil
    }

    func setTorch(_ on: Bool) {
        guard let camera = device, camera.hasTorch, (try? camera.lockForConfiguration()) != nil else { return }
        camera.torchMode = on ? .on : .off
        camera.unlockForConfiguration()
    }

    func start() {
        if !session.isRunning { session.startRunning() }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    func setZoom(_ factor: Double) {
        guard let camera = device, (try? camera.lockForConfiguration()) != nil else { return }
        camera.videoZoomFactor = CGFloat(factor)
        camera.unlockForConfiguration()
    }

    /// Focus and exposure on `point`, in the camera's own 0 to 1 frame.
    func focus(at point: CGPoint) {
        guard let camera = device, (try? camera.lockForConfiguration()) != nil else { return }
        if camera.isFocusPointOfInterestSupported {
            camera.focusPointOfInterest = point
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
        }
        if camera.isExposurePointOfInterestSupported {
            camera.exposurePointOfInterest = point
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
        }
        camera.unlockForConfiguration()
    }

    /// Takes a JPEG, or a HEIC when `original` is asked for and the camera writes it, turned by `angle`, the camera's own turn for how
    /// the phone is held, so the file's orientation is right. `completion` gets the file's bytes and extension, or nil bytes.
    func capture(flash: Bool, angle: CGFloat, original: Bool, completion: @escaping @Sendable (Data?, String) -> Void) {
        queue.async {
            let heic = original && self.output.availablePhotoCodecTypes.contains(.hevc)
            let ext = heic ? "heic" : "jpg"
            guard self.session.isRunning, heic || self.output.availablePhotoCodecTypes.contains(.jpeg),
                  let connection = self.output.connection(with: .video), connection.isEnabled, connection.isActive else {
                completion(nil, ext)
                return
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: heic ? AVVideoCodecType.hevc : AVVideoCodecType.jpeg])
            if self.scanning { settings.maxPhotoDimensions = self.output.maxPhotoDimensions }
            if flash, self.output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
            let id = settings.uniqueID
            // The output holds its delegate weakly, so it is kept here until the photo is in.
            self.pending[id] = PhotoDelegate { [weak self] data in
                self?.queue.async { self?.pending[id] = nil }
                completion(data, ext)
            }
            self.output.capturePhoto(with: settings, delegate: self.pending[id]!)
        }
    }
}
#endif
