import AppKit
import LazySendMac

// The Mac app of the App Store build. Everything it does is in the package (Sources/LazySendMac and the shared
// LazySendKit and LazySendServer); this target only starts it.
NSApplication.shared.setActivationPolicy(.regular)
LazySendApp.main()
