#if os(iOS)
import AVFoundation
import ImageIO
import SwiftUI
import UIKit

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
        watching.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        })
    }

    deinit {
        watching.forEach { NotificationCenter.default.removeObserver($0) }
        let box = capture
        box.queue.async { box.stop() }
    }

    var session: AVCaptureSession { capture.session }

    /// The camera runs while its tab is in front and the app is active.
    func setActive(_ active: Bool) async {
        if !active {
            running = false
            let box = capture
            box.queue.async { box.stop() }
            return
        }
        var state = CameraAvailability.current
        if state == .available, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
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
        Task { await setActive(true) }
    }

    func flip() {
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
                    self.availability = .noCamera
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

    /// The JPEG of a photo, or nil when none could be taken.
    func takePhoto() async -> Data? {
        guard !busy, running else { return nil }
        busy = true
        defer { busy = false }
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        let box = capture
        let withFlash = flash && hasFlash
        return await withCheckedContinuation { continuation in
            box.capture(flash: withFlash, angle: angle) { continuation.resume(returning: $0) }
        }
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
