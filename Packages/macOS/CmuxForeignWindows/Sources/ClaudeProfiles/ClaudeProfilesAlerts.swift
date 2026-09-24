import AppKit
import CmuxForeignWindows

/// Small modal prompts. The app is an accessory, so each one activates it
/// first or the alert opens behind other apps.
@MainActor
enum ClaudeProfilesAlerts {
    static func show(message: String, information: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        alert.runModal()
    }

    /// Asks for a new profile name.
    ///
    /// - Returns: The normalized name, or `nil` when cancelled or blank.
    static func askForProfileName() -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "New Claude Profile"
        alert.informativeText = "Each profile is its own Claude sign-in. "
            + "Names use lowercase letters, digits, dot, dash, and underscore."
        alert.addButton(withTitle: "Create and Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "work"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        return ClaudeDesktopProfileName(typed).rawValue
    }
}
