#if os(iOS)
import AVFoundation
import ImageIO
import LazySendScan
import LazySendScanModel
import SwiftUI
import UIKit

/// A shot or a page waiting for the corner editor: the photo upright, the corners to start from and what the answer is for.
struct CornerRequest: Identifiable {
    let id = UUID()
    let photo: RgbaImage
    let source: Data
    let corners: Quad
    let filter: CaptureFilter
    /// The page a recut replaces; nil for a new shot.
    let replacing: UUID?
}

enum CornerAnswer {
    case use(Quad)
    case whole
    case cancel
}

/// The scan mode of the camera tab: the live outline of the page, the shutter's decision (automatic or by hand), the pages
/// taken so far and what a page becomes (found, cut out and cleaned up with the filter chosen). Pages stay in memory as
/// JPEGs until Done sends them. The camera itself stays `CameraModel`'s: the frames come from its session and the photos
/// from its photo output.
@MainActor
final class ScanModel: ObservableObject {
    @Published private(set) var pages: [ScanPage] = []
    @Published private(set) var live: LiveQuadUpdate?
    /// A shot is being read, cut out and cleaned up.
    @Published private(set) var working = false
    /// The corner editor for a shot the page was not clearly found in, and for a page cut again from the page stack.
    @Published var shotEditing: CornerRequest?
    @Published var pageEditing: CornerRequest?
    @Published var problem: String?
    /// The file name of the last scan sent, which is how its row in the timeline is found.
    @Published private(set) var lastName: String?

    private weak var camera: CameraModel?
    private let tracker = LiveQuadTracker()
    private var feed: ScanFrameFeed?
    /// The video output is in the session (scan mode in front of a running camera), and frames are handed to the tracker.
    private var attached = false
    private var flowing = false
    /// Auto waits this long after the camera starts, so opening the app over a page does not take it at once.
    private var graceEnds = Date.distantPast
    private var thumbnails: [UUID: UIImage] = [:]
    private let finder: CornerModel? = FastViTCornerModel.isAvailable ? FastViTCornerModel.shared : nil
    /// Set by the owner of the settings: the filter new pages get, whether the shutter is automatic, and whether there is a
    /// device for the scan to go to, which a page is not taken without.
    var filter = CaptureFilter.enhanced
    var hasTarget = false {
        didSet { if hasTarget && !oldValue { tracker.reset() } }
    }
    var auto = true {
        didSet { if auto && !oldValue { tracker.rearm() } }
    }

    /// Scan mode is in front of a running camera on the camera tab with the app active (`active`, which is also when the camera
    /// runs) and the camera can be used: the video output is in the session.
    nonisolated static func attaches(active: Bool, scanning: Bool, cameraReady: Bool) -> Bool {
        active && scanning && cameraReady
    }

    /// Frames are handed to the tracker while the output is in the session and a sheet or the corner editor is not covering it.
    /// A cover only stops them, since taking the output out and back would restart the camera's format each time.
    nonisolated static func flows(attached: Bool, covered: Bool) -> Bool {
        attached && !covered
    }

    /// What the shutter's decision comes to: the photo is taken; or, when a photo cannot be taken now (one is being made, no
    /// device, Auto's wait after the camera started) the tracker forgets the decision, since it would otherwise keep the page as
    /// taken and never decide again; or nothing, with Auto off, where the decision stands for when it is turned on.
    enum AutoShot: Equatable {
        case take
        case forget
        case none
    }

    nonisolated static func autoShot(_ update: LiveQuadUpdate, auto: Bool, canShoot: Bool, inGrace: Bool) -> AutoShot {
        guard update.shouldCapture, auto else { return .none }
        return canShoot && !inGrace ? .take : .forget
    }

    func configure(camera: CameraModel) {
        self.camera = camera
    }

    func setLive(attached on: Bool, covered: Bool) {
        guard let camera else { return }
        if on != attached {
            attached = on
            if ScanDemo.isOn {
                // The Simulator has no camera: the frames are the demo's.
            } else if on {
                let feed = ScanFrameFeed(model: finder)
                self.feed = feed
                graceEnds = Date().addingTimeInterval(CaptureStability.autoGraceMs / 1000)
                camera.setFrames(feed)
            } else {
                feed?.stop()
                feed = nil
                camera.setFrames(nil)
                camera.setTorch(false)
                tracker.pause()
                flowing = false
                live = nil
                return
            }
        }
        let flow = ScanModel.flows(attached: attached, covered: covered)
        guard flow != flowing else { return }
        flowing = flow
        if ScanDemo.isOn {
            live = flow ? ScanDemo.update : nil
        } else if flow {
            let tracker = tracker
            feed?.start { [weak self] frame in
                guard let update = tracker.process(frame) else { return }
                Task { @MainActor in self?.apply(update) }
            }
        } else {
            feed?.stop()
            tracker.pause()
            live = nil
        }
    }

    private func apply(_ update: LiveQuadUpdate) {
        guard flowing else { return }
        live = update
        switch ScanModel.autoShot(update, auto: auto, canShoot: canShoot, inGrace: Date() < graceEnds) {
        case .take: shoot()
        case .forget: tracker.reset()
        case .none: break
        }
    }

    /// A photo can be taken: a camera that runs, no shot being worked on and no editor open.
    var canShoot: Bool {
        guard let camera else { return false }
        let ready = ScanDemo.isOn || (camera.availability == .available && !camera.interrupted && !camera.busy)
        return ready && hasTarget && !working && shotEditing == nil && pageEditing == nil
    }

    // MARK: Taking a page

    func shoot() {
        guard canShoot, let camera else { return }
        working = true
        problem = nil
        tracker.markCaptured()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let filter = filter
        let searcher = ScanDemo.isOn ? ScanDemo.finder : finder
        Task {
            var data: Data?
            if ScanDemo.isOn {
                data = ScanDemo.photo
            } else {
                data = await camera.takePhoto(format: .jpeg, flash: false)?.data
            }
            guard let data else {
                working = false
                problem = String(localized: "The photo could not be taken.")
                tracker.reset()
                return
            }
            let outcome = await Task.detached(priority: .userInitiated) { ScanModel.read(data, filter: filter, finder: searcher) }.value
            working = false
            switch outcome {
            case .page(let page):
                add(page)
            case .corners(let photo, let corners):
                shotEditing = CornerRequest(photo: photo, source: data, corners: corners, filter: filter, replacing: nil)
            case .failed:
                problem = String(localized: "The photo could not be read.")
                tracker.reset()
            }
        }
    }

    private enum Outcome: Sendable {
        case page(ScanPage)
        case corners(RgbaImage, Quad)
        case failed
    }

    /// A shot read, its page looked for and, when it is found clearly, cut out; else the photo and the corners to start from.
    private nonisolated static func read(_ data: Data, filter: CaptureFilter, finder: CornerModel?) -> Outcome {
        guard let photo = PhotoReader.decode(data) else { return .failed }
        let found = PageFinder.find(photo, model: finder)
        if found.clear, let page = PagePipeline.page(photo: photo, source: data, corners: found.corners, filter: filter) {
            return .page(page)
        }
        return .corners(photo, found.corners)
    }

    // MARK: The corner editor

    /// What the editor was asked for, answered: the page is cut along the corners as placed, or is the whole photo, or the
    /// shot is dropped (a retake) and a recut leaves the page as it was.
    func answer(_ request: CornerRequest, _ answer: CornerAnswer) {
        if shotEditing?.id == request.id { shotEditing = nil }
        if pageEditing?.id == request.id { pageEditing = nil }
        var corners = request.corners
        var whole = false
        switch answer {
        case .cancel:
            // The page still in view may be taken again.
            tracker.reset()
            return
        case .use(let placed):
            corners = placed
        case .whole:
            whole = true
        }
        let cut = corners
        let wholePhoto = whole
        working = true
        Task {
            let page = await Task.detached(priority: .userInitiated) { () -> ScanPage? in
                let id = request.replacing ?? UUID()
                if wholePhoto {
                    return PagePipeline.wholePage(photo: request.photo, source: request.source, filter: request.filter, id: id)
                }
                return PagePipeline.page(photo: request.photo, source: request.source, corners: cut, filter: request.filter, id: id)
            }.value
            working = false
            guard let page else {
                problem = String(localized: "The page could not be cut out.")
                return
            }
            add(page)
        }
    }

    /// The page added at the end, or in place of the page it was cut again from.
    func add(_ page: ScanPage) {
        thumbnails[page.id] = nil
        if let index = pages.firstIndex(where: { $0.id == page.id }) {
            pages[index] = page
        } else {
            pages.append(page)
            lastName = nil
        }
    }

    /// The page cut again: its photo is read and the editor opens at the corners it was cut along.
    func recut(_ page: ScanPage) {
        guard !working else { return }
        working = true
        Task {
            let photo = await Task.detached(priority: .userInitiated) { PhotoReader.decode(page.source) }.value
            working = false
            guard let photo else {
                problem = String(localized: "The photo could not be read.")
                return
            }
            let corners = PageFinder.clamped(page.corners, width: photo.width, height: photo.height)
            pageEditing = CornerRequest(photo: photo, source: page.source, corners: corners, filter: page.filter, replacing: page.id)
        }
    }

    // MARK: The pages

    func delete(_ id: UUID) {
        pages.removeAll { $0.id == id }
        thumbnails[id] = nil
    }

    func move(from source: IndexSet, to destination: Int) {
        pages.move(fromOffsets: source, toOffset: destination)
    }

    /// `id` one place earlier (`by` -1) or later (1).
    func shift(_ id: UUID, by step: Int) {
        guard let index = pages.firstIndex(where: { $0.id == id }), pages.indices.contains(index + step) else { return }
        pages.swapAt(index, index + step)
    }

    /// The pages went in one file named `name`.
    func sent(_ name: String) {
        lastName = name
        pages = []
        thumbnails = [:]
        tracker.reset()
    }

    /// A small picture of the page, kept until the page changes.
    func thumbnail(_ page: ScanPage) -> UIImage? {
        if let kept = thumbnails[page.id] { return kept }
        guard let source = CGImageSourceCreateWithData(page.jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 360]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: small)
        thumbnails[page.id] = image
        return image
    }
}
#endif
