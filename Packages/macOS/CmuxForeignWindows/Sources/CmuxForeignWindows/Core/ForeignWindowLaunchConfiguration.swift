public import Foundation

/// How a ``ForeignWindowSession`` finds and launches its external application.
///
/// The session resolves the application in order: ``preferredApplicationURL``
/// when it exists on disk, then the installed app for ``bundleIdentifier``,
/// then the first existing entry of ``fallbackApplicationURLs``. Every launch
/// creates a new application instance, hidden and not activated.
public struct ForeignWindowLaunchConfiguration: Equatable, Sendable {
    /// Bundle identifier of the application to host.
    public let bundleIdentifier: String
    /// An explicit application bundle to prefer, for example a dev build.
    public let preferredApplicationURL: URL?
    /// Locations checked when Launch Services does not know the bundle.
    public let fallbackApplicationURLs: [URL]
    /// Command-line arguments passed to the new instance.
    public let arguments: [String]
    /// Extra environment for the new instance; empty inherits the default.
    public let environment: [String: String]
    /// Directories created before launch, such as a per-profile data directory.
    public let directoriesToCreate: [URL]

    /// Creates a launch configuration.
    ///
    /// - Parameter bundleIdentifier: Bundle identifier of the application to host.
    /// - Parameter preferredApplicationURL: An application bundle to prefer when it exists.
    /// - Parameter fallbackApplicationURLs: Locations checked when Launch Services has no match.
    /// - Parameter arguments: Command-line arguments for the new instance.
    /// - Parameter environment: Extra environment for the new instance.
    /// - Parameter directoriesToCreate: Directories created before launching.
    public init(
        bundleIdentifier: String,
        preferredApplicationURL: URL? = nil,
        fallbackApplicationURLs: [URL] = [],
        arguments: [String] = [],
        environment: [String: String] = [:],
        directoriesToCreate: [URL] = []
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.preferredApplicationURL = preferredApplicationURL
        self.fallbackApplicationURLs = fallbackApplicationURLs
        self.arguments = arguments
        self.environment = environment
        self.directoriesToCreate = directoriesToCreate
    }
}
