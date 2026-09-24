import AppKit
import CmuxForeignWindows

/// One window with a split view: each pane hosts a Claude Desktop profile.
///
/// Clicking a pane's placeholder focuses it. The Lab menu toggles a yield so
/// the hide/restore path can be exercised without cmux's floating UI.
@MainActor
final class LabWindowController: NSObject, NSWindowDelegate {
    private struct Pane {
        let panelID: UUID
        let profile: String
        let hostView: ForeignWindowHostView
    }

    private let hosting: ClaudeDesktopHosting
    private let window: NSWindow
    private var panes: [Pane] = []
    private var focusedIndex = 0
    private var yieldToken: ForeignWindowYieldCoordinator.Token?

    init(hosting: ClaudeDesktopHosting, profiles: [String]) {
        self.hosting = hosting
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Foreign Window Lab: " + profiles.joined(separator: " | ")
        window.isReleasedWhenClosed = false
        window.delegate = self

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        for (index, profile) in profiles.enumerated() {
            let panelID = UUID()
            hosting.registry.claim(profile: profile, panelID: panelID)
            let hostView = ForeignWindowHostView(
                panelID: panelID,
                profile: profile,
                registry: hosting.registry,
                accessibility: hosting.accessibility
            )
            hostView.onRequestPanelFocus = { [weak self] in
                self?.focus(index)
            }
            split.addArrangedSubview(hostView)
            panes.append(Pane(panelID: panelID, profile: profile, hostView: hostView))
        }
        window.contentView = split
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        refresh()
        // Split subviews get their sizes after the first layout pass.
        let split = window.contentView as? NSSplitView
        split?.adjustSubviews()
    }

    @objc func toggleYield(_ sender: Any?) {
        _ = sender
        if let yieldToken {
            hosting.yieldCoordinator.endYield(yieldToken)
            self.yieldToken = nil
        } else {
            yieldToken = hosting.yieldCoordinator.beginYield(reason: "lab-toggle")
        }
    }

    @objc func focusNextPane(_ sender: Any?) {
        _ = sender
        guard !panes.isEmpty else { return }
        focus((focusedIndex + 1) % panes.count)
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        for pane in panes {
            pane.hostView.detach()
            hosting.registry.releasePanel(pane.panelID)
        }
        panes.removeAll()
        NSApp.terminate(nil)
    }

    private func focus(_ index: Int) {
        focusedIndex = index
        refresh()
    }

    private func refresh() {
        for (index, pane) in panes.enumerated() {
            pane.hostView.update(
                isFocused: index == focusedIndex,
                isVisibleInUI: true,
                backgroundColor: .windowBackgroundColor
            )
        }
    }
}
