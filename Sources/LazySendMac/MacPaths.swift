#if os(macOS)
import Foundation
import LazySendServer

enum MacPaths {
    /// Settings and state live in the app's own Application Support folder (the container, when sandboxed); received
    /// files go to the real Downloads folder, which the sandbox opens through its Downloads entitlement.
    static func standard() -> SendPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lazy Send", isDirectory: true)
        return SendPaths(root: support, defaultReceiveRoot: realHome().appendingPathComponent("Downloads/Lazy Send", isDirectory: true))
    }

    /// The user's home, not the container's: `NSHomeDirectory()` is the container in a sandbox.
    static func realHome() -> URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
#endif
