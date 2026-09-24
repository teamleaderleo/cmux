import AppKit
import CmuxForeignWindows
import os

/// Composition root: the profile store, the instance tracker, the link
/// router, and the status item.
@MainActor
final class ClaudeProfilesAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.cmuxterm.claudeprofiles", category: "app")
    private let store = ClaudeDesktopProfileStore(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        environment: ProcessInfo.processInfo.environment
    )
    private let autoOpenURL = ClaudeDesktopAutoOpenConfiguration.defaultURL(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )
    private let processLedger = ForeignWindowProcessLedger()
    private var instances: ClaudeProfilesInstances?
    private var router: ClaudeDesktopLinkRouter?
    private var statusMenu: ClaudeProfilesStatusMenu?
    private var workspaceObservers: [any NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let instances = ClaudeProfilesInstances(store: store, logger: logger)
        self.instances = instances

        // Only an app bundle can be the claude:// handler.
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let routerLog = Logger(subsystem: "com.cmuxterm.claudeprofiles", category: "router")
            let router = ClaudeDesktopLinkRouter(
                handlerApplicationURL: bundleURL,
                processLedger: processLedger,
                logger: ForeignWindowLogger { routerLog.info("\($0, privacy: .public)") }
            )
            processLedger.onChange = { [weak router] owned in
                if owned.isEmpty {
                    router?.releaseSchemeIfUnused()
                } else {
                    router?.claimSchemeIfNeeded()
                }
            }
            self.router = router
        }

        statusMenu = ClaudeProfilesStatusMenu(
            instances: instances,
            routingEnabled: router != nil,
            autoOpenURL: autoOpenURL,
            logger: logger
        )

        instances.onChange = { [weak self] in
            guard let self, let instances = self.instances else { return }
            self.processLedger.reconcile(Set(instances.running.values))
        }
        instances.refresh()
        if instances.running.isEmpty {
            // A previous run may have quit without handing claude:// back.
            router?.restoreIfOrphaned()
        } else {
            processLedger.reconcile(Set(instances.running.values))
        }
        observeWorkspace()
        openAutoOpenProfiles()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let routed = router?.route(url) ?? false
            logger.info(
                "received \(url.scheme ?? "", privacy: .public)://\(url.host ?? "", privacy: .public)\(url.path, privacy: .public) routed=\(routed)"
            )
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard application?.bundleIdentifier == ClaudeDesktopProfileStore.bundleIdentifier else { return }
                MainActor.assumeIsolated {
                    self?.instances?.refresh()
                }
            }
            workspaceObservers.append(observer)
        }
    }

    private func openAutoOpenProfiles() {
        guard let instances else { return }
        let configuration: ClaudeDesktopAutoOpenConfiguration
        do {
            configuration = try ClaudeDesktopAutoOpenConfiguration.load(from: autoOpenURL)
        } catch {
            logger.error("unreadable \(self.autoOpenURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        for profile in configuration.profilesToOpen(running: Set(instances.running.keys)) {
            instances.open(profile)
        }
    }
}
