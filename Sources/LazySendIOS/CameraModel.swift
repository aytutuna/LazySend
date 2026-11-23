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

/// One of the lens buttons: a zoom as a multiple of the main lens's view.
struct LensStop: Identifiable {
    let value: Double
    var id: Double { value }
}

@MainActor
final class CameraModel: ObservableObject {
    @Published private(set) var availability = CameraAvailability.current
    @Published private(set) var position = AVCaptureDevice.Position.back
    @Published var flash = false
    @Published private(set) var hasFlash = false
    /// Scan mode's light, which stays on while pages are taken.
    @Published private(set) var torch = false
    @Published private(set) var hasTorch = false
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
    private var lowest = 1.0
    /// The zoom now, 1 at the main lens's view; 0.5 is the ultra wide lens where the phone has one.
    @Published private(set) var zoomLevel = 1.0
    @Published private(set) var stops: [LensStop] = []
    private var highest = 1.0
    private var telephoto: Double?
    private var crop = false
    private var zoomNow = 1.0
    private var zoomAnimation: Task<Void, Never>?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationWatch: NSKeyValueObservation?
    private var watching: [NSObjectProtocol] = []
    /// The live frames of scan mode, and the turn that makes them upright, which the rotation coordinator gives.
    private var frameFeed: ScanFrameFeed?
    private var previewAngle: CGFloat = 90

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
            let light = torch
            torch = false
            box.queue.async {
                if light { box.setTorch(false) }
                box.stop()
            }
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
                self.telephoto = setup.telephoto
                self.crop = setup.crop
                self.lowest = setup.lowest
                self.zoomNow = setup.base
                self.zoomLevel = 1
                self.stops = CameraModel.lensStops(base: setup.base, lowest: setup.lowest, highest: setup.highest, telephoto: setup.telephoto, crop: setup.crop)
                self.hasFlash = setup.flash
                if !setup.flash { self.flash = false }
                self.hasTorch = setup.torch
                self.torch = false
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
                    self?.previewAngle = angle
                    self?.frameFeed?.setUprightTurn(angle)
                    guard let connection = self?.previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
                    connection.videoRotationAngle = angle
                }
            }
        }
    }

    /// Scan mode's frames go to `feed` while it is given, and stop with nil. Scanning is with the back camera.
    func setFrames(_ feed: ScanFrameFeed?) {
        frameFeed = feed
        feed?.setUprightTurn(previewAngle)
        if feed != nil, position == .front { flip() }
        let box = capture
        box.queue.async {
            let top = box.setFrames(feed)
            Task { @MainActor in self.zoomReset(highest: top) }
        }
    }

    // The session goes back to the starting zoom with every format change, and the new format has its own top.
    private func zoomReset(highest top: Double?) {
        if let top { highest = top }
        zoomAnimation?.cancel()
        zoomNow = base
        zoomLevel = 1
        stops = CameraModel.lensStops(base: base, lowest: lowest, highest: highest, telephoto: telephoto, crop: crop)
    }

    func setTorch(_ on: Bool) {
        torch = on && hasTorch
        let box = capture
        let wanted = torch
        box.queue.async { box.setTorch(wanted) }
    }

    func focus(at point: CGPoint) -> Bool {
        let box = capture
        box.queue.async { box.focus(at: point) }
        return true
    }

    /// The zoom now, 1 at the starting view.
    var zoom: Double { zoomNow / base }

    /// The most the zoom goes to, as a multiple of the starting view.
    var zoomCeiling: Double { highest / base }

    func setZoom(_ zoom: Double) {
        zoomAnimation?.cancel()
        applyZoom(zoom)
    }

    /// Moves to `level` in about a fifth of a second, by equal steps in the ratio so the view changes at an even pace.
    func animateZoom(to level: Double) {
        zoomAnimation?.cancel()
        let from = zoomLevel
        zoomAnimation = Task { @MainActor in
            let steps = 12
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
                let t = Double(step) / Double(steps)
                applyZoom(from * pow(level / from, t * t * (3 - 2 * t)))
            }
        }
    }

    private func applyZoom(_ zoom: Double) {
        zoomNow = min(max(zoom * base, lowest), max(base, highest))
        zoomLevel = zoomNow / base
        let box = capture
        let factor = zoomNow
        box.queue.async { box.setZoom(factor) }
    }

    /// A photo in `format` with its file extension, or nil when none could be taken. Original is HEIC where the camera writes it,
    /// else JPEG; PNG is made from the JPEG, with its turn put into the pixels. `flash` overrides the flash button, which
    /// scan mode leaves out.
    func takePhoto(format: PhotoFormat, flash useFlash: Bool? = nil) async -> (data: Data, ext: String)? {
        guard !busy, running else { return nil }
        busy = true
        defer { busy = false }
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        let box = capture
        let withFlash = (useFlash ?? flash) && hasFlash
        let shot: (Data?, String) = await withCheckedContinuation { continuation in
            box.capture(flash: withFlash, angle: angle, original: format == .original) { continuation.resume(returning: ($0, $1)) }
        }
        guard let data = shot.0 else { return nil }
        guard format == .png else { return (data, shot.1) }
        // A shot that cannot be made a PNG is sent as it was taken.
        guard let png = await Task.detached(operation: { PhotoFormatting.png(fromPhoto: data) }).value else { return (data, shot.1) }
        return (png, "png")
    }

    func shot(_ name: String, photo: Data) {
        lastName = name
        Task {
            let small = await Task.detached { CameraModel.thumbnail(of: photo) }.value
            thumbnail = small
        }
    }

    /// The lens buttons as multiples of the main lens: the ultra wide where the zoom goes below it, 1, and the telephoto lens where the
    /// phone has one; the main lens doubled where the phone has no telephoto or crops its 48 megapixel main camera.
    nonisolated static func lensStops(base: Double, lowest: Double, highest: Double, telephoto: Double?, crop: Bool = false) -> [LensStop] {
        var values = [1.0]
        if lowest < base { values.insert(lowest / base, at: 0) }
        if (crop || telephoto == nil) && base * 2 <= highest { values.append(2) }
        if let tele = telephoto, tele > base, tele <= highest, abs(tele / base - 2) > 0.01 { values.append(tele / base) }
        return values.map { LensStop(value: $0) }
    }

    nonisolated static func thumbnail(of photo: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(photo as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 200]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}
#endif
