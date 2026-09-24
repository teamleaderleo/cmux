import AppKit
public import Darwin

/// Finds running Claude Desktop instances that use a cmux profile directory.
///
/// An instance belongs to a profile when it was launched with
/// `--user-data-dir=<root>/<profile>`, whoever launched it: a cmux pane, the
/// `claude-profile` CLI, or the Claude Profiles menu-bar app. Reading launch
/// arguments rather than remembering launches means instances started before
/// the caller are found too.
public enum ClaudeDesktopRunningProfiles {
    /// Maps each profile to the process using it, from process arguments.
    ///
    /// Processes without a `--user-data-dir`, or with one outside
    /// `store.rootURL`, are ignored. When two processes name one profile, the
    /// lower process identifier wins, so the result is deterministic.
    ///
    /// - Parameter processArguments: Each candidate process's arguments.
    /// - Parameter store: Profile locations.
    /// - Returns: Process identifier by profile name.
    public static func profiles(
        in processArguments: [pid_t: [String]],
        store: ClaudeDesktopProfileStore
    ) -> [String: pid_t] {
        var result: [String: pid_t] = [:]
        for (processIdentifier, arguments) in processArguments {
            guard let directory = ClaudeDesktopDiagnostics.userDataDirectory(in: arguments),
                  let profile = store.profile(forDataDirectory: URL(fileURLWithPath: directory)) else {
                continue
            }
            if let existing = result[profile], existing < processIdentifier { continue }
            result[profile] = processIdentifier
        }
        return result
    }

    /// Scans running Claude Desktop instances.
    ///
    /// - Parameter store: Profile locations.
    /// - Returns: Process identifier by profile name.
    @MainActor
    public static func scan(store: ClaudeDesktopProfileStore) -> [String: pid_t] {
        let reader = ProcessArgumentsReader()
        var processArguments: [pid_t: [String]] = [:]
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: ClaudeDesktopProfileStore.bundleIdentifier
        ) where !application.isTerminated {
            let processIdentifier = application.processIdentifier
            if let arguments = reader.arguments(of: processIdentifier) {
                processArguments[processIdentifier] = arguments
            }
        }
        return profiles(in: processArguments, store: store)
    }
}
