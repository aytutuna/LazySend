// swift-tools-version: 6.0
import PackageDescription

// LazySendKit is the phone side of the link in CONTRACTS.md and needs Foundation and Network only, so the
// Mac app can use it too. LazySendIOS holds the iPhone's views and services (every file is wrapped in
// `#if os(iOS)`); ios/project.yml starts it from a thin app target. LazySendServer is the computer's side of
// the link. The code stays in the Swift 5 language mode.
let package = Package(
    name: "LazySend",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "LazySendKit", targets: ["LazySendKit"]),
        .library(name: "LazySendIOS", targets: ["LazySendIOS"]),
        .library(name: "LazySendServer", targets: ["LazySendServer"]),
    ],
    targets: [
        .target(name: "LazySendKit", path: "Sources/LazySendKit"),
        .target(name: "LazySendIOS", dependencies: ["LazySendKit"], path: "Sources/LazySendIOS"),
        .target(name: "LazySendServer", dependencies: ["LazySendKit"], path: "Sources/LazySendServer"),
        .testTarget(
            name: "LazySendKitTests",
            dependencies: ["LazySendKit"],
            path: "Tests/LazySendKitTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LazySendIOSTests",
            dependencies: ["LazySendKit", "LazySendIOS"],
            path: "Tests/LazySendIOSTests"
        ),
        .testTarget(
            name: "LazySendServerTests",
            dependencies: ["LazySendKit", "LazySendServer"],
            path: "Tests/LazySendServerTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
