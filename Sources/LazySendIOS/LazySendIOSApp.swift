#if os(iOS)
import BackgroundTasks
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var path: [Route] = []
    @State private var tab = AppTab.camera
    // The tab Pair was opened from, which the app goes back to when Pair closes.
    @State private var pairOrigin: AppTab?
    @StateObject private var camera = CameraModel()
    @StateObject private var scan = ScanModel(store: ScanModel.liveStore())

    var body: some View {
        TabView(selection: $tab) {
            Tab("Camera", systemImage: "camera", value: AppTab.camera) {
                CameraView(camera: camera, scan: scan, timeline: model.timeline, active: tab == .camera && phase == .active, pair: pair,
                           showHistory: { openFiles([]) })
            }
            Tab("Files", systemImage: "folder", value: AppTab.files) {
                NavigationStack(path: $path) {
                    MainView(timeline: model.timeline, go: go)
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .send: SendView()
                            case .pair: PairView(pair: model.pairing)
                            case .pcs: PcsView(go: go)
                            case .receive: ReceiveView(host: model.host)
                            }
                        }
                }
            }
            Tab("Clipboard", systemImage: "doc.on.clipboard", value: AppTab.clipboard) {
                ClipboardView(timeline: model.timeline, pair: pair)
            }
        }
        .overlay(alignment: .top) {
            if let copied = model.copied {
                Text(copied)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("clip.banner")
            }
        }
        .animation(.default, value: model.copied)
        .onChange(of: phase, initial: true) { _, new in
            model.sceneChanged(new)
        }
        .onChange(of: tab == .camera && phase == .active, initial: true) { _, active in
            camera.setActive(active)
        }
        .onChange(of: path) { old, new in
            if old.contains(.pair), !new.contains(.pair), let origin = pairOrigin {
                pairOrigin = nil
                tab = origin
            }
        }
    }

    private func go(_ route: Route) {
        if route == .pair { model.pairing.begin() }
        path.append(route)
    }

    private func pair() {
        pairOrigin = tab
        openFiles([.pair])
    }

    private func openFiles(_ route: [Route]) {
        if route.contains(.pair) { model.pairing.begin() }
        path = route
        tab = .files
    }
}

enum AppTab: Hashable {
    case camera
    case files
    case clipboard
}

/// The iPhone app. The Xcode project's app target (ios/project.yml) only starts it (`LazySendIOSApp.main()`).
/// The model is made in `init` so the background task can be registered before launch ends.
public struct LazySendIOSApp: App {
    @StateObject private var model: AppModel

    public init() {
        let made = MainActor.assumeIsolated { AppModel(env: .live()) }
        _model = StateObject(wrappedValue: made)
        if made.env.background {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: Keys.check, using: nil) { task in
                let work = Task { @MainActor in
                    await made.check()
                    task.setTaskCompleted(success: true)
                }
                task.expirationHandler = { work.cancel() }
            }
            BackgroundGallery.register(onExpire: { made.pauseGallery() }, isActive: { made.galleryRunning })
        }
    }

    public var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}
#endif
