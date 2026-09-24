import AppKit

// Claude Profiles: a menu-bar launcher for one Claude Desktop instance per
// account, plus claude:// sign-in routing while those instances run.
// Build the app bundle with scripts/build-profiles-app.sh; only a bundle can
// be the claude:// handler.

let application = NSApplication.shared
let delegate = ClaudeProfilesAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
