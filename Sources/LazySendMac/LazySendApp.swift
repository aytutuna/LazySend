#if os(macOS)
import AppKit
import LazySendServer
import SwiftUI

/// Everything the app and its delegate share, made once before any window or address arrives.
@MainActor
final class AppHost {
    static let shared = AppHost()

    let model: AppModel?
    let failure: String?

    private init() {
        do {
            let identity = try CertificateStore(hostName: AppHost.computerName()).current(now: Date())
            let service = try LinkService(paths: MacPaths.standard(), identity: identity)
            service.router.desktopName = { AppHost.computerName() }
            model = AppModel(service: service, advertiser: Advertiser(), notify: { Notifications.post($0, $1) })
            failure = nil
        } catch {
            model = nil
            failure = "Lazy Send could not start: \(error.localizedDescription)"
        }
    }

    nonisolated static func computerName() -> String {
        Host.current().localizedName ?? "Mac"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppHost.shared.model?.open(urls)
    }
}

public struct LazySendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    public init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    public var body: some Scene {
        Window("Lazy Send", id: "main") {
            if let model = AppHost.shared.model {
                MainView(model: model)
                    .onAppear {
                        model.resumeReceiveFolder()
                        model.start()
                        Notifications.request()
                        NSApp.activate(ignoringOtherApps: true)
                    }
            } else {
                Text(AppHost.shared.failure ?? "").padding(40).frame(minWidth: 480, minHeight: 200)
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Pair a Phone...") {
                    if let model = AppHost.shared.model { Task { await model.beginPairing() } }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        Settings {
            if let model = AppHost.shared.model { SettingsView(model: model) }
        }
        MenuBarExtra("Lazy Send", systemImage: "paperplane") {
            if let model = AppHost.shared.model {
                MenuBarContent(model: model)
            }
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Lazy Send") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Pair a Phone...") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.beginPairing() }
        }
        Divider()
        Text(model.phones.isEmpty ? "No phone is paired" : "\(model.phones.count) phone(s) paired")
        if !model.status.isEmpty { Text(model.status) }
        Divider()
        Button("Quit Lazy Send") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
#endif
