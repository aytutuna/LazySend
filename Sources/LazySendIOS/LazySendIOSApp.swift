#if os(iOS)
import BackgroundTasks
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var path: [Route] = []
    @State private var tab = AppTab.camera
    @StateObject private var camera = CameraModel()

    var body: some View {
        TabView(selection: $tab) {
            Tab("Camera", systemImage: "camera", value: AppTab.camera) {
                CameraView(camera: camera, timeline: model.timeline, active: tab == .camera && phase == .active, pair: pair,
                           showHistory: { openFiles([]) })
            }
            Tab("Files", systemImage: "folder", value: AppTab.files) {
                NavigationStack(path: $path) {
                    MainView(timeline: model.timeline, go: { path.append($0) })
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .send: SendView()
                            case .pair: PairView(app: model)
                            case .pcs: PcsView(go: { path.append($0) })
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
    }

    private func pair() {
        openFiles([.pair])
    }

    private func openFiles(_ route: [Route]) {
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
