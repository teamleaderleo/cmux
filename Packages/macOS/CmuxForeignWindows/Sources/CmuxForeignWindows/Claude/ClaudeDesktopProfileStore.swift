public import Foundation

/// Where Claude Desktop profiles live and how to launch one.
///
/// Claude Desktop is Electron, which allows one process per
/// `--user-data-dir`. Each profile gets its own directory under ``rootURL``
/// and therefore its own process and sign-in.
///
/// Paths and the environment arrive through `init`, so tests pass a temporary
/// root:
///
/// ```swift
/// let store = ClaudeDesktopProfileStore(rootURL: temporaryDirectory)
/// #expect(store.profilesOnDisk() == ["work"])
/// ```
public struct ClaudeDesktopProfileStore: Sendable {
    /// Claude Desktop's bundle identifier.
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"

    /// Environment variable naming a Claude.app to prefer over the installed one.
    public static let applicationPathEnvironmentKey = "CMUX_CLAUDE_DESKTOP_APP_PATH"

    /// Directory holding one subdirectory per profile.
    public let rootURL: URL
    /// A Claude.app to prefer over the installed one, such as a dev build.
    public let preferredApplicationURL: URL?
    /// User-local Applications folder checked as a fallback install location.
    public let userApplicationsURL: URL

    /// Creates a store with explicit locations.
    ///
    /// - Parameter rootURL: Directory holding one subdirectory per profile.
    /// - Parameter preferredApplicationURL: A Claude.app to prefer, if any.
    /// - Parameter userApplicationsURL: The user's `~/Applications` folder.
    public init(
        rootURL: URL,
        preferredApplicationURL: URL? = nil,
        userApplicationsURL: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Applications", isDirectory: true)
    ) {
        self.rootURL = rootURL
        self.preferredApplicationURL = preferredApplicationURL
        self.userApplicationsURL = userApplicationsURL
    }

    /// Creates the store cmux uses: profiles under
    /// `~/Library/Application Support/cmux/external-apps/claude`, and the app
    /// override from ``applicationPathEnvironmentKey``.
    ///
    /// - Parameter homeDirectory: The user's home directory.
    /// - Parameter environment: Process environment to read the override from.
    public init(
        homeDirectory: URL,
        environment: [String: String]
    ) {
        let override = environment[Self.applicationPathEnvironmentKey].flatMap { rawPath -> URL? in
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: trimmed)
        }
        self.init(
            rootURL: Self.defaultRootURL(homeDirectory: homeDirectory),
            preferredApplicationURL: override,
            userApplicationsURL: homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        )
    }

    /// cmux's profile root under `homeDirectory`.
    ///
    /// - Parameter homeDirectory: The user's home directory.
    /// - Returns: `~/Library/Application Support/cmux/external-apps/claude`.
    public static func defaultRootURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
            .appendingPathComponent("external-apps/claude", isDirectory: true)
    }

    /// The data directory for `profile`.
    ///
    /// - Parameter profile: A normalized profile name.
    /// - Returns: The profile's `--user-data-dir`.
    public func profileDirectoryURL(profile: String) -> URL {
        rootURL.appendingPathComponent(profile, isDirectory: true)
    }

    /// The profile whose data directory is `directoryURL`, if it is one.
    ///
    /// - Parameter directoryURL: A `--user-data-dir` value.
    /// - Returns: The profile name when `directoryURL` is a direct child of
    ///   ``rootURL`` with a normalized name.
    public func profile(forDataDirectory directoryURL: URL) -> String? {
        let root = rootURL.standardizedFileURL.path
        let candidate = directoryURL.standardizedFileURL
        guard candidate.deletingLastPathComponent().path == root else { return nil }
        let name = candidate.lastPathComponent
        return ClaudeDesktopProfileName.isNormalized(name) ? name : nil
    }

    /// Profile names that have a data directory on disk, sorted.
    ///
    /// Directories whose names are not normalized profile names are ignored.
    ///
    /// - Parameter fileManager: File manager used to list ``rootURL``.
    /// - Returns: Sorted profile names.
    public func profilesOnDisk(fileManager: FileManager = .default) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.compactMap { url -> String? in
            let isDirectory = (try? url.resourceValues(
                forKeys: [.isDirectoryKey]
            ))?.isDirectory == true
            guard isDirectory else { return nil }
            let name = url.lastPathComponent
            return ClaudeDesktopProfileName.isNormalized(name) ? name : nil
        }
        .sorted()
    }

    /// How to launch Claude Desktop for `profile`.
    ///
    /// - Parameter profile: A normalized profile name.
    /// - Returns: A configuration that creates the profile directory and
    ///   passes it as `--user-data-dir`.
    public func launchConfiguration(profile: String) -> ForeignWindowLaunchConfiguration {
        let profileDirectoryURL = profileDirectoryURL(profile: profile)
        return ForeignWindowLaunchConfiguration(
            bundleIdentifier: Self.bundleIdentifier,
            preferredApplicationURL: preferredApplicationURL,
            fallbackApplicationURLs: [
                URL(fileURLWithPath: "/Applications/Claude.app"),
                userApplicationsURL.appendingPathComponent("Claude.app", isDirectory: true)
            ],
            arguments: [
                "--user-data-dir=\(profileDirectoryURL.path)"
            ],
            directoriesToCreate: [profileDirectoryURL]
        )
    }
}
