import AppKit
import CoreServices
import Foundation

/// Routes `claude://` links while cmux hosts Claude Desktop instances.
///
/// macOS delivers a `claude://` link to one running Claude.app instance, not
/// to the one that asked for it. A pane's Google sign-in ends with
/// `claude://login/google-auth?code=…&hop_nonce=…`; when that lands in another
/// instance, it is dropped ("does not answer a sign-in this app started"), and
/// the pane never signs in.
///
/// While cmux owns Claude processes it makes itself the `claude` scheme handler
/// and forwards each link by process id:
/// - `claude://login/…` goes to every running Claude instance. Each instance
///   ignores codes whose `hop_nonce` it did not issue, so only the instance that
///   started that sign-in accepts it.
/// - Any other link goes to the user's own (non-cmux) Claude instance, or
///   launches Claude with it when none is running.
/// The previous handler is restored when cmux quits, and on the next launch if
/// cmux quit without restoring it.
@MainActor
final class ClaudeDesktopLinkRouter {
    static let shared = ClaudeDesktopLinkRouter()

    static let scheme = "claude"
    nonisolated static let claudeBundleIdentifier = "com.anthropic.claudefordesktop"

    private var claimed = false
    private var terminationObserver: NSObjectProtocol?

    private init() {}

    /// Called at launch: gives the scheme back to Claude if a previous cmux run
    /// claimed it and quit (or crashed) before restoring it.
    func restoreIfOrphaned() {
        guard !claimed, currentHandlerIsCmux else { return }
        restoreClaudeHandler()
    }

    /// Makes cmux the `claude` handler. Idempotent; called whenever cmux
    /// launches a Claude process for a pane.
    func claimSchemeIfNeeded() {
        guard !claimed, let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let status = LSSetDefaultHandlerForURLScheme(
            Self.scheme as CFString,
            bundleIdentifier as CFString
        )
        claimed = status == noErr
#if DEBUG
        cmuxDebugLog("claudeLinkRouter.claim status=\(status) bundle=\(bundleIdentifier)")
#endif
        guard claimed, terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ClaudeDesktopLinkRouter.shared.restoreClaudeHandler()
            }
        }
    }

    /// Returns true when `url` is a `claude://` link this router handled.
    func route(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Self.scheme else { return false }
        let instances = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.claudeBundleIdentifier)
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
        let owned = ForeignWindowSession.ownedProcessIdentifiers
        let isSignInCallback = url.host?.lowercased() == "login"
        let targets = isSignInCallback
            ? instances
            : instances.filter { !owned.contains($0.processIdentifier) }.prefix(1).map { $0 }
#if DEBUG
        cmuxDebugLog(
            "claudeLinkRouter.route signIn=\(isSignInCallback) path=\(url.host ?? "")\(url.path) "
                + "targets=\(targets.map(\.processIdentifier)) owned=\(owned.sorted())"
        )
#endif
        if targets.isEmpty {
            openInNewClaudeInstance(url)
            return true
        }
        for application in targets {
            send(url, to: application.processIdentifier)
        }
        return true
    }

    private var currentHandlerIsCmux: Bool {
        guard let probe = URL(string: "\(Self.scheme)://"),
              let handlerURL = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
            return false
        }
        return handlerURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func restoreClaudeHandler() {
        let status = LSSetDefaultHandlerForURLScheme(
            Self.scheme as CFString,
            Self.claudeBundleIdentifier as CFString
        )
        claimed = false
#if DEBUG
        cmuxDebugLog("claudeLinkRouter.restore status=\(status)")
#endif
    }

    /// Sends a GetURL Apple Event to one process, which is how macOS itself
    /// delivers URL opens, so Claude handles it exactly like a normal link.
    private func send(_ url: URL, to processIdentifier: pid_t) {
        let target = NSAppleEventDescriptor(processIdentifier: processIdentifier)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(string: url.absoluteString),
            forKeyword: AEKeyword(keyDirectObject)
        )
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 5)
        } catch {
#if DEBUG
            cmuxDebugLog(
                "claudeLinkRouter.sendFailed pid=\(processIdentifier) "
                    + "error=\(error.localizedDescription)"
            )
#endif
        }
    }

    private func openInNewClaudeInstance(_ url: URL) {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.claudeBundleIdentifier
        ) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        // Pane instances are running; a fresh instance is the user's own.
        configuration.createsNewApplicationInstance =
            !ForeignWindowSession.ownedProcessIdentifiers.isEmpty
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: configuration
        )
    }
}
