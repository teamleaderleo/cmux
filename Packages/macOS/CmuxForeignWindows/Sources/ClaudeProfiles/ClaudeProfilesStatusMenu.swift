import AppKit
import CmuxForeignWindows
import ServiceManagement
import os

/// The status item and its menu, rebuilt each time it opens.
@MainActor
final class ClaudeProfilesStatusMenu: NSObject, NSMenuDelegate {
    private let instances: ClaudeProfilesInstances
    private let routingEnabled: Bool
    private let autoOpenURL: URL
    private let logger: Logger
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(
        instances: ClaudeProfilesInstances,
        routingEnabled: Bool,
        autoOpenURL: URL,
        logger: Logger
    ) {
        self.instances = instances
        self.routingEnabled = routingEnabled
        self.autoOpenURL = autoOpenURL
        self.logger = logger
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Claude Profiles")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Claude Profiles"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        instances.refresh()
        menu.removeAllItems()

        let profiles = instances.allProfiles
        if profiles.isEmpty {
            let empty = menu.addItem(withTitle: "No profiles yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
        for profile in profiles {
            let title = instances.isLaunching(profile) ? "\(profile) (opening…)" : profile
            let item = menu.addItem(withTitle: title, action: #selector(openProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile
            item.state = instances.isRunning(profile) ? .on : .off
            if let processIdentifier = instances.running[profile] {
                item.toolTip = "Running, pid \(processIdentifier). Click to bring it forward."
            } else {
                item.toolTip = "Click to open."
            }
        }

        menu.addItem(.separator())
        let newProfile = menu.addItem(withTitle: "New Profile…", action: #selector(newProfile(_:)), keyEquivalent: "n")
        newProfile.target = self
        let reveal = menu.addItem(withTitle: "Reveal Profiles Folder", action: #selector(revealProfiles(_:)), keyEquivalent: "")
        reveal.target = self

        menu.addItem(.separator())
        let routing = menu.addItem(withTitle: routingStatus(), action: nil, keyEquivalent: "")
        routing.isEnabled = false

        menu.addItem(.separator())
        let autoOpenItem = menu.addItem(withTitle: "Open on Login", action: nil, keyEquivalent: "")
        autoOpenItem.submenu = autoOpenSubmenu(profiles: profiles)
        let launchAtLogin = menu.addItem(
            withTitle: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Claude Profiles",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
    }

    private func routingStatus() -> String {
        let handlerName = URL(string: "\(ClaudeDesktopLinkRouter.scheme)://")
            .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            .map { $0.deletingPathExtension().lastPathComponent } ?? "none"
        guard routingEnabled else {
            return "Sign-in routing: off, not an app bundle (handler: \(handlerName))"
        }
        let state = instances.running.isEmpty ? "off" : "on"
        return "Sign-in routing: \(state) (handler: \(handlerName))"
    }

    private func autoOpenSubmenu(profiles: [String]) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let configuration: ClaudeDesktopAutoOpenConfiguration?
        do {
            configuration = try ClaudeDesktopAutoOpenConfiguration.load(from: autoOpenURL)
        } catch {
            configuration = nil
            let item = submenu.addItem(withTitle: "claude-profiles.json is unreadable", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        for profile in profiles {
            let item = submenu.addItem(withTitle: profile, action: #selector(toggleAutoOpen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile
            item.state = configuration?.contains(profile) == true ? .on : .off
            item.isEnabled = configuration != nil
        }
        if profiles.isEmpty {
            let item = submenu.addItem(withTitle: "No profiles yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        return submenu
    }

    @objc private func openProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        instances.open(profile)
    }

    @objc private func newProfile(_ sender: NSMenuItem) {
        guard let profile = ClaudeProfilesAlerts.askForProfileName() else { return }
        instances.open(profile)
    }

    @objc private func revealProfiles(_ sender: NSMenuItem) {
        let root = instances.store.rootURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    @objc private func toggleAutoOpen(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? String else { return }
        do {
            try ClaudeDesktopAutoOpenConfiguration.load(from: autoOpenURL)
                .toggling(profile)
                .save(to: autoOpenURL)
        } catch {
            logger.error("auto-open update failed: \(error.localizedDescription, privacy: .public)")
            ClaudeProfilesAlerts.show(
                message: "Could not update Open on Login",
                information: "\(autoOpenURL.path): \(error.localizedDescription)"
            )
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            logger.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
            ClaudeProfilesAlerts.show(
                message: "Could not change Launch at Login",
                information: error.localizedDescription
            )
        }
    }
}
