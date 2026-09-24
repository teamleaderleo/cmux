import AppKit
import ApplicationServices
public import Foundation

/// A headless snapshot of the state Claude panes depend on.
///
/// Collecting it opens no windows and launches nothing: it reads the
/// Accessibility trust state of the calling process, the current `claude://`
/// handler, and every running Claude Desktop instance with the
/// `--user-data-dir` it was launched with.
public struct ClaudeDesktopDiagnostics: Codable, Equatable, Sendable {
    /// One running Claude Desktop process.
    public struct Instance: Codable, Equatable, Sendable {
        /// The process identifier.
        public let processIdentifier: Int32
        /// Path of the running app bundle, if known.
        public let bundlePath: String?
        /// The `--user-data-dir` argument, or `nil` for Claude's default profile.
        public let userDataDirectory: String?
        /// The cmux profile whose directory the instance uses, if any. A
        /// non-`nil` value means a cmux pane launched it.
        public let cmuxProfile: String?
        /// Whether the calling process's ledger lists this process.
        public let isOwnedByThisProcess: Bool
        /// Whether the app is hidden.
        public let isHidden: Bool
        /// Launch time, if known.
        public let launchDate: Date?
    }

    /// Whether the calling process is trusted for Accessibility. A terminal
    /// tool inherits the trust of the terminal app that launched it.
    public let isAccessibilityTrusted: Bool
    /// The app that currently opens `claude://` links.
    public let claudeSchemeHandlerPath: String?
    /// Where Launch Services finds Claude Desktop.
    public let claudeApplicationPath: String?
    /// The profile root the snapshot was taken against.
    public let profilesRootPath: String
    /// Profile directories on disk.
    public let profilesOnDisk: [String]
    /// Running Claude Desktop instances, sorted by process identifier.
    public let instances: [Instance]

    /// Collects a snapshot.
    ///
    /// - Parameter store: Profile locations used to recognize cmux instances.
    /// - Parameter ownedProcessIdentifiers: Processes the caller launched.
    /// - Parameter fileManager: File manager used to list profiles.
    /// - Returns: The snapshot.
    @MainActor
    public static func collect(
        store: ClaudeDesktopProfileStore,
        ownedProcessIdentifiers: Set<pid_t> = [],
        fileManager: FileManager = .default
    ) -> ClaudeDesktopDiagnostics {
        let reader = ProcessArgumentsReader()
        let workspace = NSWorkspace.shared
        let handler = URL(string: "\(ClaudeDesktopLinkRouter.scheme)://")
            .flatMap { workspace.urlForApplication(toOpen: $0) }
        let application = workspace.urlForApplication(
            withBundleIdentifier: ClaudeDesktopProfileStore.bundleIdentifier
        )
        let instances = NSRunningApplication
            .runningApplications(withBundleIdentifier: ClaudeDesktopProfileStore.bundleIdentifier)
            .filter { !$0.isTerminated }
            .map { running -> Instance in
                let pid = running.processIdentifier
                let dataDirectory = reader.arguments(of: pid).flatMap(Self.userDataDirectory(in:))
                return Instance(
                    processIdentifier: pid,
                    bundlePath: running.bundleURL?.path,
                    userDataDirectory: dataDirectory,
                    cmuxProfile: dataDirectory.flatMap {
                        store.profile(forDataDirectory: URL(fileURLWithPath: $0))
                    },
                    isOwnedByThisProcess: ownedProcessIdentifiers.contains(pid),
                    isHidden: running.isHidden,
                    launchDate: running.launchDate
                )
            }
            .sorted { $0.processIdentifier < $1.processIdentifier }
        return ClaudeDesktopDiagnostics(
            isAccessibilityTrusted: AXIsProcessTrusted(),
            claudeSchemeHandlerPath: handler?.path,
            claudeApplicationPath: application?.path,
            profilesRootPath: store.rootURL.path,
            profilesOnDisk: store.profilesOnDisk(fileManager: fileManager),
            instances: instances
        )
    }

    /// The value of a `--user-data-dir` argument, in either `=` or split form.
    ///
    /// - Parameter arguments: A process's arguments.
    /// - Returns: The directory, or `nil` when absent.
    static func userDataDirectory(in arguments: [String]) -> String? {
        let flag = "--user-data-dir"
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix(flag + "=") {
                return String(argument.dropFirst(flag.count + 1))
            }
            if argument == flag, index + 1 < arguments.count {
                return arguments[index + 1]
            }
        }
        return nil
    }

    /// A human-readable multi-line report.
    public var formattedReport: String {
        var lines: [String] = []
        lines.append("accessibility.trusted: \(isAccessibilityTrusted)")
        lines.append("claude.scheme.handler: \(claudeSchemeHandlerPath ?? "(none)")")
        lines.append("claude.app: \(claudeApplicationPath ?? "(not found)")")
        lines.append("profiles.root: \(profilesRootPath)")
        lines.append("profiles.onDisk: \(profilesOnDisk.isEmpty ? "(none)" : profilesOnDisk.joined(separator: ", "))")
        lines.append("claude.instances: \(instances.count)")
        for instance in instances {
            let owner: String
            if let profile = instance.cmuxProfile {
                owner = "cmux profile \(profile)"
            } else if instance.userDataDirectory != nil {
                owner = "custom data dir"
            } else {
                owner = "user's own"
            }
            var fields = [
                "pid=\(instance.processIdentifier)",
                "owner=\(owner)",
                "hidden=\(instance.isHidden)"
            ]
            if instance.isOwnedByThisProcess { fields.append("ownedByThisProcess=true") }
            if let dataDirectory = instance.userDataDirectory { fields.append("dataDir=\(dataDirectory)") }
            if let bundlePath = instance.bundlePath { fields.append("app=\(bundlePath)") }
            lines.append("  " + fields.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}
