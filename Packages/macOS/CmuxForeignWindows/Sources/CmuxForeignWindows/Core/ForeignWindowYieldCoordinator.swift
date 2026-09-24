public import Foundation

/// Hides hosted foreign windows while the host app floats its own UI.
///
/// Foreign (other-process) windows sit above the host app's window, so
/// anything the app floats over a pane (command palette, popovers, sheets,
/// drag previews) would render underneath them. Floating UI begins a yield;
/// every ``ForeignWindowSession`` sharing this coordinator hides while any
/// yield is active and restores after the last one ends.
///
/// ```swift
/// let token = coordinator.beginYield(reason: "session-drag")
/// defer { coordinator.endYield(token) }
/// ```
@MainActor
public final class ForeignWindowYieldCoordinator {
    /// Posted on the main thread with this coordinator as the object whenever
    /// ``isYielding`` changes.
    public static let didChangeNotification = Notification.Name("cmux.foreignWindowYield.didChange")

    /// One active yield. Balance each token with ``endYield(_:)``.
    public struct Token: Hashable, Sendable {
        fileprivate let id = UUID()
        /// Short description of what started the yield, for diagnostics.
        public let reason: String
    }

    private var active: Set<Token> = []

    /// Creates a coordinator with no active yields.
    public init() {}

    /// Whether any yield is active.
    public var isYielding: Bool { !active.isEmpty }

    /// Starts a yield.
    ///
    /// - Parameter reason: Short description of the caller, for diagnostics.
    /// - Returns: The token to pass to ``endYield(_:)``.
    public func beginYield(reason: String) -> Token {
        let token = Token(reason: reason)
        let wasYielding = isYielding
        active.insert(token)
        if !wasYielding { postChange() }
        return token
    }

    /// Ends a yield. Ending an unknown or already-ended token does nothing.
    ///
    /// - Parameter token: A token returned by ``beginYield(reason:)``.
    public func endYield(_ token: Token) {
        guard active.remove(token) != nil, !isYielding else { return }
        postChange()
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
