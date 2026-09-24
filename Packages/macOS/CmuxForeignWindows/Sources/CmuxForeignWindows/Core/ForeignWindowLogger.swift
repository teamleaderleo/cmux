/// A diagnostic sink injected into foreign-window types.
///
/// The package never logs on its own. The app passes a sink that forwards to
/// its debug event log; tests and release builds use ``disabled``. Messages
/// are built lazily, so a disabled logger costs one branch.
///
/// ```swift
/// #if DEBUG
/// let logger = ForeignWindowLogger { cmuxDebugLog($0) }
/// #else
/// let logger = ForeignWindowLogger.disabled
/// #endif
/// ```
public struct ForeignWindowLogger: Sendable {
    private let sink: (@Sendable (String) -> Void)?

    /// A logger that discards every message without building it.
    public static let disabled = ForeignWindowLogger(optionalSink: nil)

    /// Creates a logger that forwards each message to `sink`.
    ///
    /// - Parameter sink: Receives each formatted message on the calling thread.
    public init(_ sink: @escaping @Sendable (String) -> Void) {
        self.sink = sink
    }

    private init(optionalSink: (@Sendable (String) -> Void)?) {
        self.sink = optionalSink
    }

    /// Logs `message`, building it only when a sink is installed.
    ///
    /// - Parameter message: The message to log.
    public func callAsFunction(_ message: @autoclosure () -> String) {
        guard let sink else { return }
        sink(message())
    }
}
