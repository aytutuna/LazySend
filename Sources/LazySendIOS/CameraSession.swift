#if os(iOS)
import AVFoundation

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
    var highest: Double
    var flash: Bool
}

/// The capture session and its photo output. Every method runs on `queue`, so the session is set up, started and
/// stopped off the main thread.
final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "LazySend.camera")
    private let output = AVCapturePhotoOutput()
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
        let base = CameraLens.startZoom(camera)
        setZoom(base)
        return CameraSetup(device: camera, base: base, highest: min(Double(camera.maxAvailableVideoZoomFactor), base * 10),
                           flash: output.supportedFlashModes.contains(.on))
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

    /// Takes a JPEG turned by `angle`, the camera's own turn for how the phone is held, so the file's orientation is right.
    /// `completion` gets the file's bytes, or nil.
    func capture(flash: Bool, angle: CGFloat, completion: @escaping @Sendable (Data?) -> Void) {
        queue.async {
            guard self.session.isRunning, self.output.availablePhotoCodecTypes.contains(.jpeg),
                  let connection = self.output.connection(with: .video), connection.isEnabled, connection.isActive else {
                completion(nil)
                return
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            if flash, self.output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
            let id = settings.uniqueID
            // The output holds its delegate weakly, so it is kept here until the photo is in.
            self.pending[id] = PhotoDelegate { [weak self] data in
                self?.queue.async { self?.pending[id] = nil }
                completion(data)
            }
            self.output.capturePhoto(with: settings, delegate: self.pending[id]!)
        }
    }
}
#endif
