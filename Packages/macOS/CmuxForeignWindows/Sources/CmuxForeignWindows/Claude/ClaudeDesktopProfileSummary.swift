/// A Claude Desktop profile (account) as an account switcher sees it.
public struct ClaudeDesktopProfileSummary: Equatable, Sendable {
    /// The normalized profile name.
    public let name: String
    /// A profile directory exists on disk.
    public let existsOnDisk: Bool
    /// At least one open panel uses the profile.
    public let isInUse: Bool
    /// The profile's Claude process is running.
    public let isRunning: Bool

    /// Creates a summary.
    ///
    /// - Parameter name: The normalized profile name.
    /// - Parameter existsOnDisk: Whether a profile directory exists.
    /// - Parameter isInUse: Whether an open panel uses the profile.
    /// - Parameter isRunning: Whether its process is running.
    public init(name: String, existsOnDisk: Bool, isInUse: Bool, isRunning: Bool) {
        self.name = name
        self.existsOnDisk = existsOnDisk
        self.isInUse = isInUse
        self.isRunning = isRunning
    }
}
