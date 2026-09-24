public import CoreGraphics

/// What ``ForeignWindowProfileRegistry`` needs from the process-owning session
/// of one profile.
///
/// ``ForeignWindowSession`` is the production conformance. Tests supply a fake
/// through the registry's session factory.
@MainActor
public protocol ForeignWindowProfileSession: AnyObject {
    /// Whether the external process is currently running.
    var isRunning: Bool { get }

    /// The external process, while it runs.
    var processIdentifier: pid_t? { get }

    /// Moves, shows, hides, or focuses the external window.
    ///
    /// - Parameter targetFrame: Screen rect in Accessibility (top-left origin)
    ///   coordinates, or `nil` when no host is presenting.
    /// - Parameter isVisible: Whether the window should be shown.
    /// - Parameter isFocused: Whether the external app should be activated.
    /// - Parameter raiseWindow: Whether to raise the window above its siblings.
    func updatePresentation(
        targetFrame: CGRect?,
        isVisible: Bool,
        isFocused: Bool,
        raiseWindow: Bool
    )

    /// Tears down observers and terminates the external process.
    func invalidate()
}
