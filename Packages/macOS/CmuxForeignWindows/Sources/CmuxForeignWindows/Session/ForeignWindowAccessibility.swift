import AppKit
import ApplicationServices
public import Foundation

/// Whether this process may move other apps' windows (macOS Accessibility).
///
/// Without it, a hosted app's window cannot be placed over its pane, so it
/// would float wherever the app opens it. Sessions keep hosted apps hidden
/// while access is missing, and hosts show a prompt instead. While any caller
/// is interested and access is missing, this polls once a second so a grant in
/// System Settings takes effect without relaunching anything.
@MainActor
public final class ForeignWindowAccessibility {
    /// Posted on the main thread with this instance as the object when
    /// ``isTrusted`` changes.
    public static let didChangeNotification = Notification.Name("cmux.foreignWindowAccessibility.didChange")

    /// The last observed trust state.
    public private(set) var isTrusted: Bool
    private var interestCount = 0
    // A repeating main-run-loop timer: the grant arrives from System Settings
    // with no notification, so polling while interested is the only signal.
    private var pollTimer: Timer?
    private var didPrompt = false

    /// Creates a gate reading the current trust state.
    public init() {
        isTrusted = AXIsProcessTrusted()
    }

    /// Starts watching for a grant. Balance with ``endInterest()``.
    public func beginInterest() {
        interestCount += 1
        refresh()
        updatePolling()
    }

    /// Stops one caller's interest in grant changes.
    public func endInterest() {
        interestCount = max(0, interestCount - 1)
        updatePolling()
    }

    /// Shows the system prompt once per launch, then opens the Accessibility
    /// pane of System Settings on later requests.
    public func requestAccess() {
        guard !refresh() else { return }
        if !didPrompt {
            didPrompt = true
            // The value of kAXTrustedCheckOptionPrompt, which Swift 6 rejects
            // as a mutable global.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        if let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    /// Re-reads the trust state and posts ``didChangeNotification`` on change.
    ///
    /// - Returns: Whether the process is trusted.
    @discardableResult
    public func refresh() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            updatePolling()
        }
        return trusted
    }

    private func updatePolling() {
        let shouldPoll = interestCount > 0 && !isTrusted
        if shouldPoll, pollTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                // Scheduled on the main run loop below.
                MainActor.assumeIsolated {
                    _ = self?.refresh()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !shouldPoll {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }
}
