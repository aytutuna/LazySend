#if os(macOS)
import AppKit
import LazySendKit
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
            let paths = MacPaths.standard()
            let service = try LinkService(paths: paths, identity: identity)
            service.router.desktopName = { AppHost.computerName() }
            // This Mac's own id is the id it gives the computers it connects to, as the Windows app does.
            let hosts = PcStore(file: paths.root.appendingPathComponent("hosts.json"), secrets: KeychainSecrets(),
                                phoneId: service.devices.desktopId)
            let guest = GuestService(hosts: hosts, connector: PcConnector(store: hosts), history: service.history, settings: service.settings,
                                     guestName: AppHost.computerName(),
                                     appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            model = AppModel(service: service, advertiser: Advertiser(), guest: guest, notify: { Notifications.post($0, $1) })
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppHost.shared.model?.resumeReceiveFolder()
        AppHost.shared.model?.start()
        Notifications.request()
    }

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
                Button("Connect to a Computer...") {
                    AppHost.shared.model?.beginConnecting()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
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
        Button("Connect to a Computer...") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            model.beginConnecting()
        }
        Divider()
        Text(model.phones.isEmpty ? "Nothing is paired" : "\(model.phones.count) device(s) paired")
        if !model.status.isEmpty { Text(model.status) }
        Divider()
        Button("Quit Lazy Send") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
#endif
