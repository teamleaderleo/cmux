import AppKit
public import Foundation

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
///
/// The previous handler is restored when cmux quits, and on the next launch if
/// cmux quit without restoring it. ``ClaudeDesktopHosting`` wires the router
/// to its ``ForeignWindowProcessLedger`` so claims follow owned processes.
@MainActor
public final class ClaudeDesktopLinkRouter {
    /// The URL scheme this router handles.
    nonisolated public static let scheme = "claude"

    private let handlerApplicationURL: URL
    private let processLedger: ForeignWindowProcessLedger
    private let logger: ForeignWindowLogger
    private var claimed = false
    /// Every Claude launch re-registers Claude as the `claude` handler, so a
    /// claim made while a pane's Claude is starting is immediately undone.
    /// While claimed, the router re-checks on this interval and takes the
    /// handler back if a Claude launch (a pane's or the user's own) took it.
    private var watchdog: Timer?
    private static let watchdogInterval: TimeInterval = 3

    /// The result of one attempt to make the host app the `claude` handler.
    public struct ClaimResult: Sendable {
        /// Whether Launch Services now names the host app as the handler.
        public let isHandler: Bool
        /// The handler Launch Services reports after the change.
        public let currentHandlerURL: URL?
        /// The error Launch Services returned, if any.
        public let errorDescription: String?
    }

    /// Called on the main actor after each claim, once Launch Services
    /// answered and the handler was read back.
    public var onClaimResult: (@MainActor (ClaimResult) -> Void)?
    private var terminationObserver: (any NSObjectProtocol)?

    /// Creates a router.
    ///
    /// - Parameter handlerApplicationURL: The app bundle that becomes the
    ///   `claude` handler while it owns Claude processes (the host app).
    /// - Parameter processLedger: Which Claude processes the host launched.
    /// - Parameter logger: Receives routing diagnostics.
    public init(
        handlerApplicationURL: URL,
        processLedger: ForeignWindowProcessLedger,
        logger: ForeignWindowLogger = .disabled
    ) {
        self.handlerApplicationURL = handlerApplicationURL
        self.processLedger = processLedger
        self.logger = logger
    }

    /// Called at launch: gives the scheme back to Claude if a previous cmux run
    /// claimed it and quit (or crashed) before restoring it.
    public func restoreIfOrphaned() {
        guard !claimed, currentHandlerIsCmux else { return }
        restoreClaudeHandler(waitForCompletion: false)
    }

    /// Makes cmux the `claude` handler while cmux owns Claude processes.
    /// Idempotent; called whenever cmux launches a Claude process for a pane.
    /// macOS may ask the user to confirm the change once.
    public func claimSchemeIfNeeded() {
        if !claimed {
            claimed = true
            startWatchdog()
        }
        // A pane's Claude just started; it re-registers itself as the handler
        // during launch, so claim now and again once it has settled.
        reassertClaim()
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restoreClaudeHandler(waitForCompletion: true)
            }
        }
    }

    /// Called when a cmux-owned Claude process goes away; hands the scheme back
    /// once none are left.
    public func releaseSchemeIfUnused() {
        guard claimed, processLedger.ownedProcessIdentifiers.isEmpty else { return }
        restoreClaudeHandler(waitForCompletion: false)
    }

    /// Forwards a `claude://` link to the right Claude instance.
    ///
    /// - Parameter url: A URL the host app was asked to open.
    /// - Returns: `true` when `url` is a `claude://` link this router handled.
    public func route(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Self.scheme else { return false }
        let instances = NSRunningApplication
            .runningApplications(withBundleIdentifier: ClaudeDesktopProfileStore.bundleIdentifier)
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
        let owned = processLedger.ownedProcessIdentifiers
        let isSignInCallback = url.host?.lowercased() == "login"
        let targets = isSignInCallback
            ? instances
            : instances.filter { !owned.contains($0.processIdentifier) }.prefix(1).map { $0 }
        logger(
            "claudeLinkRouter.route signIn=\(isSignInCallback) path=\(url.host ?? "")\(url.path) "
                + "targets=\(targets.map(\.processIdentifier)) owned=\(owned.sorted())"
        )
        if targets.isEmpty {
            openInNewClaudeInstance(url)
            return true
        }
        for application in targets {
            send(url, to: application.processIdentifier)
        }
        return true
    }

    /// Reads the handler back: the completion reports only that Launch
    /// Services accepted the request, not what it now resolves.
    private func verifyClaim(errorDescription: String?) {
        let currentHandlerURL = Self.currentHandlerURL()
        let isHandler = currentHandlerURL?.standardizedFileURL
            == handlerApplicationURL.standardizedFileURL
        logger(
            "claudeLinkRouter.claim ok=\(isHandler) handler=\(currentHandlerURL?.path ?? "none") "
                + "error=\(errorDescription ?? "none")"
        )
        onClaimResult?(
            ClaimResult(
                isHandler: isHandler,
                currentHandlerURL: currentHandlerURL,
                errorDescription: errorDescription
            )
        )
    }

    private static func currentHandlerURL() -> URL? {
        guard let probe = URL(string: "\(scheme)://") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    private var currentHandlerIsCmux: Bool {
        guard let handlerURL = Self.currentHandlerURL() else { return false }
        return handlerURL.standardizedFileURL == handlerApplicationURL.standardizedFileURL
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reassertClaim()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// Sets the host app as the handler when Launch Services names anyone
    /// else. Cheap when already the handler: one lookup, no write.
    private func reassertClaim() {
        guard claimed, !currentHandlerIsCmux else { return }
        setHandler(handlerApplicationURL) { [weak self] error in
            let errorDescription = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.verifyClaim(errorDescription: errorDescription)
                }
            }
        }
    }

    private func restoreClaudeHandler(waitForCompletion: Bool) {
        claimed = false
        stopWatchdog()
        guard let claudeURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: ClaudeDesktopProfileStore.bundleIdentifier
        ) else { return }
        // At quit the process may exit before the change lands, and
        // willTerminate cannot suspend, so a bounded semaphore wait is the only
        // way to hold the process until Launch Services answers.
        let done = DispatchSemaphore(value: 0)
        let logger = logger
        setHandler(claudeURL) { error in
            logger("claudeLinkRouter.restore error=\(error?.localizedDescription ?? "none")")
            done.signal()
        }
        if waitForCompletion {
            _ = done.wait(timeout: .now() + 1.5)
        }
    }

    private func setHandler(_ applicationURL: URL, completion: @escaping @Sendable ((any Error)?) -> Void) {
        NSWorkspace.shared.setDefaultApplication(
            at: applicationURL,
            toOpenURLsWithScheme: Self.scheme,
            completion: completion
        )
    }

    private func send(_ url: URL, to processIdentifier: pid_t) {
        do {
            try ForeignWindowURLEvent.send(url, to: processIdentifier)
        } catch {
            logger(
                "claudeLinkRouter.sendFailed pid=\(processIdentifier) "
                    + "error=\(error.localizedDescription)"
            )
        }
    }

    private func openInNewClaudeInstance(_ url: URL) {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: ClaudeDesktopProfileStore.bundleIdentifier
        ) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        // Pane instances are running; a fresh instance is the user's own.
        configuration.createsNewApplicationInstance =
            !processLedger.ownedProcessIdentifiers.isEmpty
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: configuration
        )
    }
}
