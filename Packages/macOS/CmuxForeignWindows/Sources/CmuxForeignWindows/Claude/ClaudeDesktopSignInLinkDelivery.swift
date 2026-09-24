public import Darwin
public import Foundation

/// Delivers a pasted sign-in link to one pane's Claude process.
///
/// Validation happens first, so a non-sign-in link never reaches any process.
/// The send step is injected: the pane passes ``ForeignWindowURLEvent`` and
/// tests pass a recorder.
public enum ClaudeDesktopSignInLinkDelivery {
    /// What happened to a paste.
    public enum Outcome: Equatable, Sendable {
        /// The link went to this process.
        case sent(pid_t)
        /// The text is not a Claude sign-in link; nothing was sent.
        case notSignInLink(ClaudeDesktopSignInLink.Rejection)
        /// The pane has no running Claude process; nothing was sent.
        case claudeNotRunning
        /// The Apple Event could not be sent.
        case sendFailed(String)
    }

    /// Validates `text` and sends it to `processIdentifier`.
    ///
    /// - Parameter text: The pasted text, or `nil` when the pasteboard holds none.
    /// - Parameter processIdentifier: This pane's Claude process, if running.
    /// - Parameter send: Delivers the URL to the process.
    /// - Returns: What happened.
    @MainActor
    public static func deliver(
        text: String?,
        to processIdentifier: pid_t?,
        send: (URL, pid_t) throws -> Void
    ) -> Outcome {
        let link: ClaudeDesktopSignInLink
        switch ClaudeDesktopSignInLink.parse(text ?? "") {
        case .success(let parsed):
            link = parsed
        case .failure(let rejection):
            return .notSignInLink(rejection)
        }
        guard let processIdentifier else { return .claudeNotRunning }
        do {
            try send(link.url, processIdentifier)
            return .sent(processIdentifier)
        } catch {
            return .sendFailed(error.localizedDescription)
        }
    }
}
