import AppKit
import CmuxForeignWindows
import Foundation

// Standalone harness for the Claude Desktop pane feature. `--diagnose` is
// headless; without it the lab opens one window with a pane per profile.

let options: LabOptions
do {
    options = try LabOptions(arguments: Array(CommandLine.arguments.dropFirst()))
} catch let error as LabOptionsError {
    if let message = error.message {
        FileHandle.standardError.write(Data("ForeignWindowLab: \(message)\n".utf8))
        FileHandle.standardError.write(Data((LabOptions.usage + "\n").utf8))
        exit(64)
    }
    print(LabOptions.usage)
    exit(0)
}

let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
let defaultStore = ClaudeDesktopProfileStore(
    homeDirectory: homeDirectory,
    environment: ProcessInfo.processInfo.environment
)
let store = options.profilesRoot.map {
    ClaudeDesktopProfileStore(
        rootURL: $0,
        preferredApplicationURL: defaultStore.preferredApplicationURL,
        userApplicationsURL: defaultStore.userApplicationsURL
    )
} ?? defaultStore

if options.diagnose {
    let report = ClaudeDesktopDiagnostics.collect(store: store)
    if options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        print(String(decoding: data, as: UTF8.self))
    } else {
        print(report.formattedReport)
    }
    exit(0)
}

let logger = options.verbose
    ? ForeignWindowLogger { message in
        FileHandle.standardError.write(Data("[lab] \(message)\n".utf8))
    }
    : ForeignWindowLogger.disabled

// An unbundled executable cannot be the claude:// handler, so link routing
// stays off; sign-in callbacks go wherever macOS sends them.
let hosting = ClaudeDesktopHosting(
    store: store,
    linkHandlerApplicationURL: nil,
    logger: logger
)
let profiles = options.profiles.map { ClaudeDesktopProfileName($0).rawValue }

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let controller = LabWindowController(hosting: hosting, profiles: profiles)
LabMenu(controller: controller).install()
controller.show()
application.activate(ignoringOtherApps: true)
application.run()
