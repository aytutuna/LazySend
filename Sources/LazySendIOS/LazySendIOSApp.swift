#if os(iOS)
import BackgroundTasks
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            MainView(timeline: model.timeline, go: { path.append($0) })
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .send: SendView()
                    case .pair: PairView(app: model)
                    case .pcs: PcsView(go: { path.append($0) })
                    }
                }
        }
        .onChange(of: phase, initial: true) { _, new in
            model.sceneChanged(new)
        }
    }
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
            BackgroundGallery.register { made.pauseGallery() }
        }
    }

    public var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}
#endif
