import CmuxForeignWindows
import Foundation

/// The app's one Claude Desktop hosting graph. cmux is the composition root:
/// panels claim profiles from its registry, floating UI yields through its
/// coordinator, and AppDelegate routes `claude://` links through its router.
@MainActor
enum ClaudeDesktopAppRuntime {
    static let hosting = ClaudeDesktopHosting(
        store: ClaudeDesktopProfileStore(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        ),
        linkHandlerApplicationURL: Bundle.main.bundleURL,
        logger: logger
    )

    private static var logger: ForeignWindowLogger {
#if DEBUG
        ForeignWindowLogger { cmuxDebugLog($0) }
#else
        ForeignWindowLogger.disabled
#endif
    }
}
