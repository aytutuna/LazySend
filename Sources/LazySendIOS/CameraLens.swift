#if os(iOS)
import AVFoundation

/// Which camera the phone uses for a side, adapted from Lazy Scan's lens choice: the virtual camera that switches
/// lenses by itself where the phone has one, else the wide lens, else whatever is there.
enum CameraLens {
    enum Kind: Int {
        case triple, dualWide, dual, wide, ultraWide, telephoto, trueDepth, other
    }

    private static let preferred: [Kind] = [.triple, .dualWide, .wide]

    private static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInTrueDepthCamera,
    ]

    static func kind(_ type: AVCaptureDevice.DeviceType) -> Kind {
        switch type {
        case .builtInTripleCamera: return .triple
        case .builtInDualWideCamera: return .dualWide
        case .builtInDualCamera: return .dual
        case .builtInWideAngleCamera: return .wide
        case .builtInUltraWideCamera: return .ultraWide
        case .builtInTelephotoCamera: return .telephoto
        case .builtInTrueDepthCamera: return .trueDepth
        default: return .other
        }
    }

    /// Lower is better: the preferred kinds in order, then the rest.
    static func rank(_ kind: Kind) -> Int {
        preferred.firstIndex(of: kind) ?? preferred.count + kind.rawValue
    }

    static func best(_ position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: position).devices
            .min { rank(kind($0.deviceType)) < rank(kind($1.deviceType)) }
    }

    /// The phone has a camera (the Simulator has none).
    static var hasCamera: Bool {
        best(.back) != nil || best(.front) != nil
    }

    /// A virtual camera with the ultra wide lens has the ultra wide view at zoom 1; it starts at the wide lens's view,
    /// where the first switch-over factor is.
    static func startZoom(_ camera: AVCaptureDevice) -> Double {
        let kind = kind(camera.deviceType)
        guard kind == .triple || kind == .dualWide, let first = camera.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue,
              first.isFinite, first > 1 else { return 1 }
        return min(first, Double(camera.maxAvailableVideoZoomFactor))
    }
}
#endif
