#if os(iOS)
import Foundation
import LazySendKit
import LazySendServer
import Security
import UIKit
import UserNotifications

enum Keys {
    static let photos = "savePhotos"
    static let selected = "selectedPc"
    static let check = "com.lazysend.lazysend.check"
    static let galleryPending = "gallerySyncPending"
}

struct Notifier: Sendable {
    var ask: @Sendable () -> Void
    var post: @Sendable (_ title: String, _ body: String) -> Void

    static let silent = Notifier(ask: {}, post: { _, _ in })

    static let live = Notifier(
        ask: {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        },
        post: { title, body in
            Task {
                let center = UNUserNotificationCenter.current()
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        })
}

/// Everything the app reads from outside itself, so a test can build a model on temp folders and memory.
struct AppEnvironment {
    var folder: URL
    var support: URL
    var documents: URL
    var secrets: SecretStore
    var discovery: Discovery
    var defaults: UserDefaults
    var notifier: Notifier
    var photos: PhotoSource
    var phoneName: String
    var appVersion: String
    var background: Bool
    var demo: Bool
    /// The certificate this phone hosts with, made on first use.
    var identity: () throws -> SecIdentity
    var advertiser: Advertiser?
    /// The addresses a pairing code and `hello` list; nil for the ones the phone has.
    var addresses: (() -> [String])?

    static let quiet = Discovery(announced: { _ in [:] }, subnets: { [] }, probe: { _, _ in [] })

    @MainActor
    static func live() -> AppEnvironment {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiTesting") { return temporary(demo: arguments.contains("-demoData"), notifier: .silent) }
        let fm = FileManager.default
        return AppEnvironment(
            folder: AppGroup.folder(),
            support: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LazySend", isDirectory: true),
            documents: fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
            secrets: KeychainSecrets(),
            discovery: .live,
            defaults: .standard,
            notifier: .live,
            photos: .live,
            phoneName: UIDevice.current.name,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            background: true,
            demo: false,
            identity: { try HostCertificate(hostName: UIDevice.current.name).current() },
            advertiser: Advertiser(),
            addresses: nil)
    }

    static func temporary(demo: Bool = false, notifier: Notifier = .silent) -> AppEnvironment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-" + UUID().uuidString, isDirectory: true)
        let folders = ["app", "support", "documents"].map { root.appendingPathComponent($0, isDirectory: true) }
        for folder in folders { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return AppEnvironment(
            folder: folders[0],
            support: folders[1],
            documents: folders[2],
            secrets: MemorySecrets(),
            discovery: quiet,
            defaults: UserDefaults(suiteName: "lazysend.tests." + UUID().uuidString) ?? .standard,
            notifier: notifier,
            photos: .none,
            phoneName: "Test phone",
            appVersion: "1.0",
            background: false,
            demo: demo,
            identity: { throw SelfSignedCertificateError("No certificate in this build.") },
            advertiser: nil,
            addresses: nil)
    }
}
#endif
