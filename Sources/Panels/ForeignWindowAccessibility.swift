import AppKit
import ApplicationServices
import Foundation

/// Whether cmux may move other apps' windows (macOS Accessibility).
///
/// Without it, a hosted app's window cannot be placed over its pane, so it
/// would float wherever the app opens it. Sessions keep hosted apps hidden
/// while access is missing, and hosts show a prompt instead. While any caller
/// is interested and access is missing, this polls once a second so a grant in
/// System Settings takes effect without relaunching anything.
@MainActor
final class ForeignWindowAccessibility {
    static let shared = ForeignWindowAccessibility()

    /// Posted on the main thread when `isTrusted` changes.
    static let didChangeNotification = Notification.Name("cmux.foreignWindowAccessibility.didChange")

    private(set) var isTrusted: Bool = AXIsProcessTrusted()
    private var interestCount = 0
    private var pollTimer: Timer?
    private var didPrompt = false

    private init() {}

    /// Starts watching for a grant. Balance with `endInterest()`.
    func beginInterest() {
        interestCount += 1
        refresh()
        updatePolling()
    }

    func endInterest() {
        interestCount = max(0, interestCount - 1)
        updatePolling()
    }

    /// Shows the system prompt once per launch, then opens the Accessibility
    /// pane of System Settings on later requests.
    func requestAccess() {
        guard !refresh() else { return }
        if !didPrompt {
            didPrompt = true
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        if let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    @discardableResult
    func refresh() -> Bool {
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
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    ForeignWindowAccessibility.shared.refresh()
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
