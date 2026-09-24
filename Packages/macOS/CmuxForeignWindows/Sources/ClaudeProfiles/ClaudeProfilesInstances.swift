import AppKit
import CmuxForeignWindows
import os

/// Tracks which profiles have a running Claude instance and launches or
/// activates them. Never starts a second process on one profile directory.
@MainActor
final class ClaudeProfilesInstances {
    let store: ClaudeDesktopProfileStore
    /// Process identifier by profile, from the last scan.
    private(set) var running: [String: pid_t] = [:]
    /// Profiles launched by this app whose process has not shown up yet.
    private var pending: Set<String> = []
    private let logger: Logger
    /// Called after ``running`` changes.
    var onChange: (() -> Void)?

    init(store: ClaudeDesktopProfileStore, logger: Logger) {
        self.store = store
        self.logger = logger
    }

    /// Profiles on disk plus any running from a directory created since.
    var allProfiles: [String] {
        Set(store.profilesOnDisk()).union(running.keys).sorted()
    }

    func isRunning(_ profile: String) -> Bool {
        running[profile] != nil
    }

    func isLaunching(_ profile: String) -> Bool {
        pending.contains(profile) && running[profile] == nil
    }

    /// Re-reads running Claude instances' launch arguments.
    func refresh() {
        let next = ClaudeDesktopRunningProfiles.scan(store: store)
        pending.subtract(next.keys)
        guard next != running else { return }
        logger.info("running profiles: \(next.description, privacy: .public)")
        running = next
        onChange?()
    }

    /// Activates the profile's instance, or launches one when none runs.
    func open(_ profile: String) {
        refresh()
        if let processIdentifier = running[profile] {
            activate(processIdentifier)
            return
        }
        guard !pending.contains(profile) else {
            logger.info("\(profile, privacy: .public) is already launching")
            return
        }
        launch(profile)
    }

    private func activate(_ processIdentifier: pid_t) {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            refresh()
            return
        }
        NSApp.yieldActivation(to: application)
        application.unhide()
        application.activate(options: [.activateAllWindows])
    }

    private func launch(_ profile: String) {
        let launchConfiguration = store.launchConfiguration(profile: profile)
        guard let applicationURL = launchConfiguration.resolveApplicationURL() else {
            logger.error("Claude.app not found")
            ClaudeProfilesAlerts.show(
                message: "Claude.app not found",
                information: "Install Claude Desktop in /Applications, then try again."
            )
            return
        }
        do {
            for directory in launchConfiguration.directoriesToCreate {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            logger.error("could not create profile folder: \(error.localizedDescription, privacy: .public)")
            ClaudeProfilesAlerts.show(
                message: "Could not create the \(profile) profile folder",
                information: error.localizedDescription
            )
            return
        }
        pending.insert(profile)
        onChange?()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = launchConfiguration.arguments
        logger.info("launching \(profile, privacy: .public)")
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] _, error in
            let errorDescription = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let errorDescription {
                    self.logger.error(
                        "launch \(profile, privacy: .public) failed: \(errorDescription, privacy: .public)"
                    )
                }
                // The process exists once the launch completes, so the scan
                // finds it; drop the guard either way so a failed launch can
                // be retried.
                self.refresh()
                if self.pending.remove(profile) != nil { self.onChange?() }
            }
        }
    }
}
