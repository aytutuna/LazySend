#if os(iOS)
import BackgroundTasks
import Foundation

/// iOS 26 can keep a sync the user started going after the app leaves the screen, with a progress bar of its own.
/// The sync itself stays in AppModel; this only registers the task, asks for it and reports progress to it.
/// Before iOS 26 every call here does nothing and the sync relies on the short background grace period.
@MainActor
enum BackgroundGallery {
    static let identifier = "com.lazysend.lazysend.gallery.sync"

    private static var running: AnyObject?

    static var isRunning: Bool { running != nil }

    /// Call before the app finishes launching. `onExpire` is called when the system ends the task; `isActive` says
    /// whether a gallery run is going, since a task that starts without one has nothing to report on.
    nonisolated static func register(onExpire: @escaping @MainActor () -> Void, isActive: @escaping @MainActor () -> Bool) {
        guard #available(iOS 26.0, *) else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            task.expirationHandler = {
                Task { @MainActor in
                    running = nil
                    onExpire()
                }
            }
            Task { @MainActor in
                if isActive() {
                    running = task
                } else {
                    task.setTaskCompleted(success: true)
                }
            }
        }
    }

    static func request(title: String, subtitle: String) {
        guard #available(iOS 26.0, *) else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .queue
        try? BGTaskScheduler.shared.submit(request)
    }

    static func update(title: String, subtitle: String, completed: Int64, total: Int64) {
        guard #available(iOS 26.0, *), let task = running as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = max(total, 1)
        task.progress.completedUnitCount = completed
        task.updateTitle(title, subtitle: subtitle)
    }

    static func finish(success: Bool) {
        guard #available(iOS 26.0, *) else { return }
        (running as? BGContinuedProcessingTask)?.setTaskCompleted(success: success)
        running = nil
    }
}
#endif
