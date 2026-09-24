import Foundation
import Testing

@testable import CmuxForeignWindows

@Suite
struct ClaudeDesktopAutoOpenConfigurationTests {
    @Test
    func testDecodeNormalizesAndDeduplicates() throws {
        let data = Data(#"{"autoOpen": ["Work", "personal", "work", "../Side Acct"]}"#.utf8)
        let configuration = try ClaudeDesktopAutoOpenConfiguration.decode(data)
        #expect(configuration.autoOpen == ["work", "personal", "side-acct"])
    }

    @Test
    func testDecodeToleratesMissingKeyAndRejectsWrongShape() throws {
        #expect(try ClaudeDesktopAutoOpenConfiguration.decode(Data("{}".utf8)).autoOpen.isEmpty)
        #expect(throws: (any Error).self) {
            try ClaudeDesktopAutoOpenConfiguration.decode(Data(#"{"autoOpen": "work"}"#.utf8))
        }
    }

    @Test
    func testToggleAndProfilesToOpen() {
        let configuration = ClaudeDesktopAutoOpenConfiguration(autoOpen: ["work", "personal"])
        #expect(configuration.toggling("Work").autoOpen == ["personal"])
        #expect(configuration.toggling("side").autoOpen == ["work", "personal", "side"])
        #expect(configuration.contains("PERSONAL"))
        #expect(configuration.profilesToOpen(running: ["work"]) == ["personal"])
    }

    @Test
    func testLoadMissingFileAndRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-autoopen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("claude-profiles.json")

        #expect(try ClaudeDesktopAutoOpenConfiguration.load(from: url).autoOpen.isEmpty)
        try ClaudeDesktopAutoOpenConfiguration(autoOpen: ["work"]).save(to: url)
        #expect(try ClaudeDesktopAutoOpenConfiguration.load(from: url).autoOpen == ["work"])
    }

    @Test
    func testDefaultURLSitsBesideProfileRoot() {
        let url = ClaudeDesktopAutoOpenConfiguration.defaultURL(
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )
        #expect(
            url.path == "/Users/tester/Library/Application Support/cmux/external-apps/claude-profiles.json"
        )
    }
}
