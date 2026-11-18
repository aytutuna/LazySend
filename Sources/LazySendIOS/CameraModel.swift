#if os(iOS)
import AVFoundation
import ImageIO
import SwiftUI
import UIKit

extension CameraAvailability {
    /// The camera tab's camera now: a camera to use (none in the Simulator) and the camera permission.
    static var current: CameraAvailability {
        resolve(isSupported: CameraLens.hasCamera, authorization: AVCaptureDevice.authorizationStatus(for: .video))
    }
}

@MainActor
final class CameraModel: ObservableObject {
    @Published private(set) var availability = CameraAvailability.current
    @Published private(set) var position = AVCaptureDevice.Position.back
    @Published var flash = false
    @Published private(set) var hasFlash = false
    @Published private(set) var interrupted = false
    @Published private(set) var busy = false
    @Published private(set) var thumbnail: UIImage?
    /// The file name of the last photo, which is how its row in the timeline is found.
    @Published private(set) var lastName: String?
    @Published var problem: String?

    private let capture = CameraSession()
    private var configured = false
    private var camera: AVCaptureDevice?
    private var running = false
    private var activation: Task<Void, Never>?
    private var base = 1.0
    private var highest = 1.0
    private var zoomNow = 1.0
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationWatch: NSKeyValueObservation?
    private var watching: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let session = capture.session
        watching.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupted = true }
        })
        watching.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupted = false }
        })
        watching.append(center.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupted = false }
        })
        watching.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            MainActor.assumeIsolated {
                if error?.code == .mediaServicesWereReset { self?.restart() }
            }
        })
    }

    deinit {
        watching.forEach { NotificationCenter.default.removeObserver($0) }
        let box = capture
        box.queue.async { box.stop() }
    }

    var session: AVCaptureSession { capture.session }

    /// The camera runs while its tab is in front and the app is active. A later call replaces one still waiting for permission.
    func setActive(_ active: Bool) {
        activation?.cancel()
        activation = Task { await self.activate(active) }
    }

    private func activate(_ active: Bool) async {
        if !active {
            running = false
            let box = capture
            box.queue.async { box.stop() }
            return
        }
        interrupted = false
        var state = CameraAvailability.current
        if state == .available, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            state = CameraAvailability.current
        }
        availability = state
        guard state == .available else { return }
        running = true
        if configured {
            let box = capture
            box.queue.async { box.start() }
        } else {
            switchCamera(to: position)
        }
    }

    func retry() {
        setActive(true)
    }

    func flip() {
        guard !busy else { return }
        switchCamera(to: position == .back ? .front : .back)
    }

    private func switchCamera(to next: AVCaptureDevice.Position) {
        let box = capture
        let wanted = running
        box.queue.async {
            let setup = box.use(next)
            if setup != nil, wanted { box.start() }
            Task { @MainActor in
                guard let setup else {
                    // The camera in use stays; only a first setup that fails means there is none.
                    if self.configured {
                        self.problem = String(localized: "The camera could not be switched.")
                    } else {
                        self.availability = .noCamera
                    }
                    return
                }
                self.configured = true
                self.camera = setup.device
                self.position = next
                self.base = setup.base
                self.highest = setup.highest
                self.zoomNow = setup.base
                self.hasFlash = setup.flash
                if !setup.flash { self.flash = false }
                self.followRotation()
            }
        }
    }

    private func restart() {
        guard running else { return }
        let box = capture
        box.queue.async { box.start() }
    }

    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = capture.session
        layer.videoGravity = .resizeAspect
        followRotation()
    }

    // The preview and the photo are turned to how the phone is held, which also sets the orientation the file carries.
    private func followRotation() {
        guard let layer = previewLayer, let camera else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: layer)
        rotation = coordinator
        rotationWatch = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let connection = self?.previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
                    connection.videoRotationAngle = angle
                }
            }
        }
    }

    func focus(at point: CGPoint) -> Bool {
        let box = capture
        box.queue.async { box.focus(at: point) }
        return true
    }

    /// The zoom now, 1 at the starting view.
    var zoom: Double { zoomNow / base }

    func setZoom(_ zoom: Double) {
        zoomNow = min(max(zoom * base, base), max(base, highest))
        let box = capture
        let factor = zoomNow
        box.queue.async { box.setZoom(factor) }
    }

    /// A photo in `format` with its file extension, or nil when none could be taken. Original is HEIC where the camera writes it,
    /// else JPEG; PNG is made from the JPEG, with its turn put into the pixels.
    func takePhoto(format: PhotoFormat) async -> (data: Data, ext: String)? {
        guard !busy, running else { return nil }
        busy = true
        defer { busy = false }
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        let box = capture
        let withFlash = flash && hasFlash
        let shot: (Data?, String) = await withCheckedContinuation { continuation in
            box.capture(flash: withFlash, angle: angle, original: format == .original) { continuation.resume(returning: ($0, $1)) }
        }
        guard let data = shot.0 else { return nil }
        guard format == .png else { return (data, shot.1) }
        guard let png = await Task.detached(operation: { PhotoFormatting.png(fromPhoto: data) }).value else { return nil }
        return (png, "png")
    }

    func shot(_ name: String, jpeg: Data) {
        lastName = name
        Task {
            let small = await Task.detached { CameraModel.thumbnail(of: jpeg) }.value
            thumbnail = small
        }
    }

    nonisolated static func thumbnail(of jpeg: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 200]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}
#endif
