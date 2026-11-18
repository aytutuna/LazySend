#if os(iOS)
import AVFoundation

/// Whether the camera can be used here, and if not, why.
enum CameraAvailability: Equatable {
    /// It can be used (asking for the camera the first time, as iOS does).
    case available
    /// This device has no camera (the Simulator).
    case noCamera
    /// The user turned camera access off for this app in Settings.
    case denied
    /// Camera access is not allowed here (Screen Time or a device profile).
    case restricted

    static func resolve(isSupported: Bool, authorization: AVAuthorizationStatus) -> CameraAvailability {
        if !isSupported { return .noCamera }
        switch authorization {
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .available
        }
    }

    static var current: CameraAvailability {
        resolve(isSupported: CameraLens.hasCamera, authorization: AVCaptureDevice.authorizationStatus(for: .video))
    }

    var reason: String? {
        switch self {
        case .available: return nil
        case .noCamera: return String(localized: "No camera here")
        case .denied: return String(localized: "Camera access is off")
        case .restricted: return String(localized: "Camera not allowed")
        }
    }
}
#endif
