import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct CmuxGhosttyConfigPathResolverTests {
    @Test func terminalKitBuildFallsBackToReleaseConfig() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let releaseConfig = try fixture.writeConfig(
            bundleIdentifier: CmuxGhosttyConfigPathResolver.releaseBundleIdentifier,
            contents: "theme = 0x96f\n"
        )

        let urls = CmuxGhosttyConfigPathResolver().loadConfigURLs(
            currentBundleIdentifier: "com.cmuxterm.app.terminal-kit",
            appSupportDirectory: fixture.root,
            fileManager: fixture.fileManager
        )

        #expect(urls == [releaseConfig])
    }

    @Test func terminalKitSpecificConfigTakesPrecedenceOverReleaseConfig() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        _ = try fixture.writeConfig(
            bundleIdentifier: CmuxGhosttyConfigPathResolver.releaseBundleIdentifier,
            contents: "theme = release\n"
        )
        let taggedConfig = try fixture.writeConfig(
            bundleIdentifier: "com.cmuxterm.app.terminal-kit",
            contents: "theme = terminal-kit\n"
        )

        let urls = CmuxGhosttyConfigPathResolver().loadConfigURLs(
            currentBundleIdentifier: "com.cmuxterm.app.terminal-kit",
            appSupportDirectory: fixture.root,
            fileManager: fixture.fileManager
        )

        #expect(urls == [taggedConfig])
    }

    @Test func unrelatedTaggedBuildDoesNotSilentlyInheritReleaseConfig() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        _ = try fixture.writeConfig(
            bundleIdentifier: CmuxGhosttyConfigPathResolver.releaseBundleIdentifier,
            contents: "theme = release\n"
        )

        let urls = CmuxGhosttyConfigPathResolver().loadConfigURLs(
            currentBundleIdentifier: "com.cmuxterm.app.some-experiment",
            appSupportDirectory: fixture.root,
            fileManager: fixture.fileManager
        )

        #expect(urls.isEmpty)
    }

    private struct Fixture {
        let fileManager = FileManager.default
        let root: URL

        init() throws {
            root = fileManager.temporaryDirectory
                .appendingPathComponent("CmuxGhosttyConfigPathResolverTests-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func writeConfig(bundleIdentifier: String, contents: String) throws -> URL {
            let directory = root.appendingPathComponent(bundleIdentifier, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("config.ghostty", isDirectory: false)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func remove() {
            try? fileManager.removeItem(at: root)
        }
    }
}
