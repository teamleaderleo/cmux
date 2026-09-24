public import Foundation

/// Profiles to open when the Claude Profiles menu-bar app starts.
///
/// Stored as plain JSON so it can be edited by hand:
///
/// ```json
/// {"autoOpen": ["work", "personal"]}
/// ```
///
/// Names are normalized with ``ClaudeDesktopProfileName`` and deduplicated in
/// order. A missing file means no profiles; a missing key means none too.
public struct ClaudeDesktopAutoOpenConfiguration: Codable, Equatable, Sendable {
    /// Normalized profile names, in the order they open.
    public private(set) var autoOpen: [String]

    private enum CodingKeys: String, CodingKey {
        case autoOpen
    }

    /// Creates a configuration.
    ///
    /// - Parameter autoOpen: Profile names; normalized and deduplicated.
    public init(autoOpen: [String] = []) {
        var seen: Set<String> = []
        self.autoOpen = autoOpen.map { ClaudeDesktopProfileName($0).rawValue }.filter {
            seen.insert($0).inserted
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(autoOpen: try container.decodeIfPresent([String].self, forKey: .autoOpen) ?? [])
    }

    /// The configuration file under `homeDirectory`.
    ///
    /// - Parameter homeDirectory: The user's home directory.
    /// - Returns: `~/Library/Application Support/cmux/external-apps/claude-profiles.json`.
    public static func defaultURL(homeDirectory: URL) -> URL {
        ClaudeDesktopProfileStore.defaultRootURL(homeDirectory: homeDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("claude-profiles.json", isDirectory: false)
    }

    /// Decodes a configuration from JSON data.
    ///
    /// - Parameter data: The file contents.
    /// - Returns: The configuration.
    /// - Throws: `DecodingError` when the data is not a JSON object of this shape.
    public static func decode(_ data: Data) throws -> ClaudeDesktopAutoOpenConfiguration {
        try JSONDecoder().decode(ClaudeDesktopAutoOpenConfiguration.self, from: data)
    }

    /// Loads the configuration at `url`.
    ///
    /// - Parameter url: The configuration file.
    /// - Returns: The configuration, or an empty one when the file is missing.
    /// - Throws: Read or decoding errors for a file that exists.
    public static func load(from url: URL) throws -> ClaudeDesktopAutoOpenConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ClaudeDesktopAutoOpenConfiguration()
        }
        return try decode(Data(contentsOf: url))
    }

    /// Writes the configuration to `url`, creating its folder.
    ///
    /// - Parameter url: The configuration file.
    /// - Throws: Encoding or write errors.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Whether `profile` opens at launch.
    ///
    /// - Parameter profile: A profile name.
    public func contains(_ profile: String) -> Bool {
        autoOpen.contains(ClaudeDesktopProfileName(profile).rawValue)
    }

    /// A copy with `profile` added when absent or removed when present.
    ///
    /// - Parameter profile: A profile name.
    /// - Returns: The updated configuration.
    public func toggling(_ profile: String) -> ClaudeDesktopAutoOpenConfiguration {
        let name = ClaudeDesktopProfileName(profile).rawValue
        return autoOpen.contains(name)
            ? ClaudeDesktopAutoOpenConfiguration(autoOpen: autoOpen.filter { $0 != name })
            : ClaudeDesktopAutoOpenConfiguration(autoOpen: autoOpen + [name])
    }

    /// The configured profiles that are not already running, in order.
    ///
    /// - Parameter running: Profiles with a live instance.
    /// - Returns: Profiles to open.
    public func profilesToOpen(running: Set<String>) -> [String] {
        autoOpen.filter { !running.contains($0) }
    }
}
