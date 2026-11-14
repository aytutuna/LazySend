// swift-tools-version: 6.0
import PackageDescription

// LazySendKit is the phone side of the link in CONTRACTS.md and needs Foundation and Network only, so the
// Mac app can use it too. LazySendIOS holds the iPhone's views and services (every file is wrapped in
// `#if os(iOS)`); ios/project.yml starts it from a thin app target. LazySendServer is the host side of
// the link, which the Mac and the iPhone both run, and LazySendMac the Mac app's views and services (every file
// is wrapped in `#if os(macOS)`); mac/project.yml starts it the same way. The code stays in the Swift 5 language mode.
let package = Package(
    name: "LazySend",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "LazySendKit", targets: ["LazySendKit"]),
        .library(name: "LazySendIOS", targets: ["LazySendIOS"]),
        .library(name: "LazySendServer", targets: ["LazySendServer"]),
        .library(name: "LazySendMac", targets: ["LazySendMac"]),
    ],
    targets: [
        .target(name: "LazySendKit", path: "Sources/LazySendKit"),
        .target(name: "LazySendIOS", dependencies: ["LazySendKit", "LazySendServer"], path: "Sources/LazySendIOS"),
        .target(name: "LazySendServer", dependencies: ["LazySendKit"], path: "Sources/LazySendServer"),
        .target(name: "LazySendMac", dependencies: ["LazySendKit", "LazySendServer"], path: "Sources/LazySendMac"),
        .testTarget(
            name: "LazySendKitTests",
            dependencies: ["LazySendKit"],
            path: "Tests/LazySendKitTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LazySendIOSTests",
            dependencies: ["LazySendKit", "LazySendServer", "LazySendIOS"],
            path: "Tests/LazySendIOSTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LazySendServerTests",
            dependencies: ["LazySendKit", "LazySendServer"],
            path: "Tests/LazySendServerTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LazySendMacTests",
            dependencies: ["LazySendKit", "LazySendServer", "LazySendMac"],
            path: "Tests/LazySendMacTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
