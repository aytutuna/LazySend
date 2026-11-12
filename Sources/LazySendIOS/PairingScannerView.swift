#if os(iOS)
import AVFoundation
import LazySendKit
import SwiftUI
import UIKit
import VisionKit

/// The camera looking for the computer's pairing code: VisionKit's live scanner where this device has it,
/// else the camera's own QR reader. The first text read that is a pairing code goes to `onCode`, once.
/// Without a camera (the Simulator) or access, one line says why and the text can be pasted instead.
struct PairingScannerView: View {
    let onCode: @MainActor (String) -> Void
    @State private var availability: CameraAvailability?
    @State private var cameraLost = false

    var body: some View {
        Group {
            if cameraLost {
                lost
            } else if let shown = availability {
                if shown.isAvailable {
                    if PairingScannerView.usesDataScanner {
                        DataScanner(onCode: onCode, onLost: { cameraLost = true })
                    } else {
                        CaptureScanner(onCode: onCode, onLost: { cameraLost = true })
                    }
                } else {
                    unavailable(shown)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            availability = await PairingScannerView.cameraAvailability()
        }
    }

    private var lost: some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode.viewfinder")
                .font(.largeTitle)
                .foregroundStyle(Color.white)
                .accessibilityHidden(true)
            Text("The camera is not available here. Paste the pairing text below instead.")
                .font(.headline)
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("pair.scanner.message")
        }
        .padding(16)
    }

    private func unavailable(_ shown: CameraAvailability) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode.viewfinder")
                .font(.largeTitle)
                .foregroundStyle(Color.white)
                .accessibilityHidden(true)
            Text(shown.reason)
                .font(.headline)
                .foregroundStyle(Color.white)
                .accessibilityIdentifier("pair.scanner.message")
            if shown == .denied {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    @MainActor
    static var usesDataScanner: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    @MainActor
    static func cameraAvailability() async -> CameraAvailability {
        let found = DataScannerViewController.isSupported || AVCaptureDevice.default(for: .video) != nil
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if found && status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            status = granted ? .authorized : .denied
        }
        return CameraAvailability.resolve(isSupported: found, authorization: status)
    }
}

enum CameraAvailability: Equatable {
    case available
    case noCamera
    case denied
    case restricted

    static func resolve(isSupported: Bool, authorization: AVAuthorizationStatus) -> CameraAvailability {
        if !isSupported { return .noCamera }
        switch authorization {
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .available
        }
    }

    var isAvailable: Bool { self == .available }

    var reason: String {
        switch self {
        case .available: return ""
        case .noCamera: return String(localized: "No camera here")
        case .denied: return String(localized: "Camera access is off")
        case .restricted: return String(localized: "Camera not allowed")
        }
    }
}

private struct DataScanner: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void
    let onLost: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onLost: onLost)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced,
                                                recognizesMultipleItems: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !scanner.isScanning {
            do {
                try scanner.startScanning()
            } catch {
                // Not while a view update is running.
                let lost = onLost
                Task { @MainActor in lost() }
            }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: @MainActor (String) -> Void
        var onLost: @MainActor () -> Void
        private var handed = false

        init(onCode: @escaping @MainActor (String) -> Void, onLost: @escaping @MainActor () -> Void) {
            self.onCode = onCode
            self.onLost = onLost
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            onLost()
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard !handed, case .barcode(let barcode) = item, let text = barcode.payloadStringValue,
                      PairingCode.looksLikeCode(text) else { continue }
                handed = true
                onCode(text)
            }
        }
    }
}

private struct CaptureScanner: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void
    let onLost: @MainActor () -> Void

    func makeUIViewController(context: Context) -> CaptureController {
        CaptureController(onCode: onCode, onLost: onLost)
    }

    func updateUIViewController(_ controller: CaptureController, context: Context) {
        controller.onCode = onCode
        controller.onLost = onLost
    }
}

// AVFoundation wants the session started and stopped off the main thread.
private final class CaptureSession: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "LazySend.pairing.camera")

    func start() {
        queue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }
}

private final class CaptureController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: @MainActor (String) -> Void
    var onLost: @MainActor () -> Void
    private let capture = CaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var handed = false
    private var interruption: NSObjectProtocol?

    init(onCode: @escaping @MainActor (String) -> Void, onLost: @escaping @MainActor () -> Void) {
        self.onCode = onCode
        self.onLost = onLost
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let interruption {
            NotificationCenter.default.removeObserver(interruption)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black
        let session = capture.session
        // Another app using the camera beside this one (Split View, Slide Over) interrupts the session.
        interruption = NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session,
                                                              queue: .main) { [weak self] (_: Notification) in
            Task { @MainActor in self?.onLost() }
        }
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            Task { @MainActor [weak self] in self?.onLost() }
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        // Only once the output is in the session does it offer QR codes.
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        capture.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        capture.stop()
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        var texts: [String] = []
        for object in metadataObjects {
            if let code = object as? AVMetadataMachineReadableCodeObject, let text = code.stringValue {
                texts.append(text)
            }
        }
        MainActor.assumeIsolated {
            self.read(texts)
        }
    }

    private func read(_ texts: [String]) {
        for text in texts where !handed && PairingCode.looksLikeCode(text) {
            handed = true
            onCode(text)
        }
    }
}
#endif
