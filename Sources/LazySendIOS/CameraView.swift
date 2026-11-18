#if os(iOS)
import AVFoundation
import LazySendKit
import SwiftUI
import UIKit

/// The camera tab: a live viewfinder, and every photo goes to the chosen device's clipboard as soon as it is taken.
struct CameraView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var camera: CameraModel
    @ObservedObject var timeline: Timeline
    let active: Bool
    let pair: () -> Void
    let showHistory: () -> Void
    @State private var sentHidden = false

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(camera: camera, active: active && camera.availability == .available && !camera.interrupted)
                    .ignoresSafeArea()
                if let line = shownMessage {
                    card(line)
                }
                chrome(wide: wide)
            }
        }
        .onChange(of: camera.lastName) { _, _ in sentHidden = false }
        .onChange(of: entry?.state) { _, state in
            guard state == .done else { return }
            sentHidden = false
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                sentHidden = true
            }
        }
    }

    private var shownMessage: String? {
        if !camera.availability.isAvailable { return camera.availability.reason }
        return camera.interrupted ? String(localized: "Camera paused") : nil
    }

    private func card(_ line: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.largeTitle)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            Text(line)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("camera.message")
            if camera.availability == .denied {
                Button("Settings") { openSettings() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("camera.settings")
            }
            if camera.availability == .denied || camera.availability == .restricted {
                Button("Retry") { camera.retry() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("camera.retry")
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.12)))
        .padding()
    }

    private func chrome(wide: Bool) -> some View {
        let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        let controls = wide ? AnyLayout(VStackLayout(spacing: 24)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            VStack(spacing: 12) {
                topBar
                if model.targets.isEmpty { pairCard }
                if let problem = camera.problem {
                    Text(problem).font(.footnote).foregroundStyle(.white).padding(8).background(Color.red.opacity(0.8), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            if !wide { Spacer(minLength: 0) }
            controls {
                thumbnail
                if !wide { Spacer() }
                shutter
                if !wide { Spacer() }
                flip
            }
            .padding(wide ? .horizontal : .vertical, 20)
            .padding(.horizontal, wide ? 0 : 24)
            .frame(maxHeight: wide ? .infinity : nil)
        }
    }

    private var topBar: some View {
        HStack {
            if camera.hasFlash {
                Button { camera.flash.toggle() } label: {
                    Image(systemName: camera.flash ? "bolt.fill" : "bolt.slash.fill")
                        .foregroundStyle(camera.flash ? Color.yellow : Color.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.4), in: Circle())
                }
                .accessibilityLabel(camera.flash ? "Flash on" : "Flash off")
                .accessibilityIdentifier("camera.flash")
            }
            Menu {
                Picker("Format", selection: Binding(get: { model.photoFormat }, set: { model.setPhotoFormat($0) })) {
                    ForEach(PhotoFormat.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Text(model.photoFormat.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.4), in: Capsule())
            }
            .accessibilityIdentifier("camera.format")
            Spacer()
            if let target = model.selectedTarget {
                Menu {
                    Picker("Send to", selection: Binding(get: { target.id }, set: { model.select($0) })) {
                        ForEach(model.targets) { Text($0.name).tag($0.id) }
                    }
                } label: {
                    Label(target.name, systemImage: target.phone ? "iphone" : "laptopcomputer")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.4), in: Capsule())
                }
                .accessibilityIdentifier("camera.target")
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var pairCard: some View {
        VStack(spacing: 10) {
            Text("Pair a device to send photos")
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("camera.pairTitle")
            Button("Pair a device", action: pair)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("camera.pair")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.55)))
        .padding(.horizontal)
    }

    private var shutter: some View {
        Button { shoot() } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                Circle().fill(Color.white).frame(width: 60, height: 60)
            }
            .opacity(canShoot ? 1 : 0.4)
        }
        .disabled(!canShoot)
        .accessibilityLabel("Take photo")
        .accessibilityIdentifier("camera.shutter")
    }

    private var flip: some View {
        Button { camera.flip() } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.black.opacity(0.4), in: Circle())
        }
        .opacity(camera.availability == .available && !camera.busy ? 1 : 0.4)
        .disabled(camera.availability != .available || camera.busy)
        .accessibilityLabel("Switch camera")
        .accessibilityIdentifier("camera.flip")
    }

    private var thumbnail: some View {
        Button(action: showHistory) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.15))
                    if let image = camera.thumbnail {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if let line = statusLine {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityIdentifier("camera.status")
                }
            }
            .frame(width: 70, height: 72, alignment: .top)
        }
        .accessibilityLabel("Photo history")
        .accessibilityIdentifier("camera.thumbnail")
    }

    private var canShoot: Bool {
        camera.availability == .available && !camera.interrupted && !camera.busy && model.selectedTarget != nil
    }

    /// The row of the last photo; nil until the send has made one.
    private var entry: TimelineEntry? {
        guard let name = camera.lastName else { return nil }
        return timeline.entries.first { $0.direction == .sent && $0.kind == .file && $0.title == name }
    }

    private var statusLine: String? {
        guard camera.lastName != nil, let who = entry?.pcName ?? model.selectedTarget?.name else { return nil }
        switch entry?.state {
        case .done: return sentHidden ? nil : String(localized: "Sent to \(who)")
        case .failed: return String(localized: "Not sent")
        default: return String(localized: "Waiting for \(who)")
        }
    }

    private func shoot() {
        guard let target = model.selectedTarget else { return }
        camera.problem = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { @MainActor in
            guard let photo = await camera.takePhoto(format: model.photoFormat) else {
                camera.problem = String(localized: "The photo could not be taken.")
                return
            }
            do {
                camera.shot(try await model.sendCameraPhoto(photo.data, ext: photo.ext, to: target), jpeg: photo.data)
            } catch {
                camera.problem = error.localizedDescription
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

/// The session's live picture. A tap focuses and a pinch zooms.
struct CameraPreview: UIViewRepresentable {
    let camera: CameraModel
    /// A tap focuses and a pinch zooms only while this is true.
    let active: Bool

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.camera = camera
        camera.attach(view.previewLayer)
        return view
    }

    func updateUIView(_ view: CameraPreviewView, context: Context) {
        view.active = active
    }
}

final class CameraPreviewView: UIView {
    weak var camera: CameraModel?
    private let focusSquare = UIView()
    private var pinchStart = 1.0
    var active = true {
        didSet {
            for recognizer in gestureRecognizers ?? [] { recognizer.isEnabled = active }
            if !active { focusSquare.alpha = 0 }
        }
    }

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // The layer class above makes this cast always succeed.
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        focusSquare.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        focusSquare.layer.borderWidth = 1.5
        focusSquare.layer.cornerRadius = 4
        focusSquare.layer.borderColor = UIColor.white.cgColor
        focusSquare.alpha = 0
        focusSquare.isUserInteractionEnabled = false
        addSubview(focusSquare)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @MainActor
    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        let spot = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        // Outside the frame is a black band.
        guard (0...1).contains(spot.x), (0...1).contains(spot.y), camera?.focus(at: spot) == true else { return }
        focusSquare.layer.removeAllAnimations()
        focusSquare.center = point
        focusSquare.alpha = 1
        UIView.animate(withDuration: 0.3, delay: 1, options: [.allowUserInteraction]) { self.focusSquare.alpha = 0 }
    }

    @MainActor
    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        guard let camera else { return }
        if pinch.state == .began { pinchStart = camera.zoom }
        if pinch.state == .changed { camera.setZoom(pinchStart * Double(pinch.scale)) }
    }
}
#endif
