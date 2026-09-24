import Foundation
import Testing

@testable import CmuxForeignWindows

@Suite
struct ClaudeDesktopProfileStoreTests {
    @Test
    func testProfilesOnDiskListsNormalizedDirectoriesOnly() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-claude-profiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        for name in ["work", "default", "Not Normalized"] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data().write(to: root.appendingPathComponent("stray-file"))

        let store = ClaudeDesktopProfileStore(rootURL: root)
        #expect(store.profilesOnDisk() == ["default", "work"])
    }

    @Test
    func testDefaultStoreUsesCmuxRootAndTrimmedAppOverride() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let store = ClaudeDesktopProfileStore(
            homeDirectory: home,
            environment: [ClaudeDesktopProfileStore.applicationPathEnvironmentKey: "  /tmp/Claude.app \n"]
        )
        #expect(
            store.rootURL.path
                == "/Users/tester/Library/Application Support/cmux/external-apps/claude"
        )
        #expect(store.preferredApplicationURL?.path == "/tmp/Claude.app")

        let blank = ClaudeDesktopProfileStore(
            homeDirectory: home,
            environment: [ClaudeDesktopProfileStore.applicationPathEnvironmentKey: "   "]
        )
        #expect(blank.preferredApplicationURL == nil)
    }

    @Test
    func testLaunchConfigurationPassesProfileDirectory() {
        let root = URL(fileURLWithPath: "/tmp/profiles", isDirectory: true)
        let store = ClaudeDesktopProfileStore(
            rootURL: root,
            userApplicationsURL: URL(fileURLWithPath: "/Users/tester/Applications", isDirectory: true)
        )
        let configuration = store.launchConfiguration(profile: "work")
        #expect(configuration.bundleIdentifier == "com.anthropic.claudefordesktop")
        #expect(configuration.arguments == ["--user-data-dir=/tmp/profiles/work"])
        #expect(configuration.directoriesToCreate.map(\.path) == ["/tmp/profiles/work"])
        #expect(
            configuration.fallbackApplicationURLs.map(\.path)
                == ["/Applications/Claude.app", "/Users/tester/Applications/Claude.app"]
        )
    }

    @Test(arguments: [
        ("/tmp/profiles/work", "work"),
        ("/tmp/profiles/work/", "work"),
        ("/tmp/profiles/Work", nil),
        ("/tmp/profiles/work/nested", nil),
        ("/tmp/other/work", nil)
    ] as [(String, String?)])
    func testProfileForDataDirectory(path: String, expected: String?) {
        let store = ClaudeDesktopProfileStore(rootURL: URL(fileURLWithPath: "/tmp/profiles", isDirectory: true))
        #expect(store.profile(forDataDirectory: URL(fileURLWithPath: path)) == expected)
    }
}
