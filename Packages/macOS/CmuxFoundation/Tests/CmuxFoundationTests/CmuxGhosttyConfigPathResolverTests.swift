import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct CmuxGhosttyConfigPathResolverTests {
    private let resolver = CmuxGhosttyConfigPathResolver()

    @Test func taggedBuildFallsBackToReleaseConfig() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let releaseDirectory = root.appendingPathComponent(
            CmuxGhosttyConfigPathResolver.releaseBundleIdentifier,
            isDirectory: true
        )
        try fileManager.createDirectory(at: releaseDirectory, withIntermediateDirectories: true)
        let releaseConfig = releaseDirectory.appendingPathComponent("config.ghostty")
        try "theme = 0x96f\nkeybind = cmd+a=text:\\x1b[25~\n".write(
            to: releaseConfig,
            atomically: true,
            encoding: .utf8
        )

        let urls = resolver.loadConfigURLs(
            currentBundleIdentifier: "com.cmuxterm.app.terminal-kit",
            appSupportDirectory: root,
            fileManager: fileManager
        )

        #expect(urls == [releaseConfig])
    }

    @Test func taggedBuildPrefersItsOwnConfig() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let releaseDirectory = root.appendingPathComponent(
            CmuxGhosttyConfigPathResolver.releaseBundleIdentifier,
            isDirectory: true
        )
        let taggedDirectory = root.appendingPathComponent(
            "com.cmuxterm.app.terminal-kit",
            isDirectory: true
        )
        try fileManager.createDirectory(at: releaseDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: taggedDirectory, withIntermediateDirectories: true)

        let releaseConfig = releaseDirectory.appendingPathComponent("config.ghostty")
        let taggedConfig = taggedDirectory.appendingPathComponent("config.ghostty")
        try "theme = release\n".write(to: releaseConfig, atomically: true, encoding: .utf8)
        try "theme = tagged\n".write(to: taggedConfig, atomically: true, encoding: .utf8)

        let urls = resolver.loadConfigURLs(
            currentBundleIdentifier: "com.cmuxterm.app.terminal-kit",
            appSupportDirectory: root,
            fileManager: fileManager
        )

        #expect(urls == [taggedConfig])
    }

    @Test func unrelatedBundleDoesNotReadReleaseConfig() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let releaseDirectory = root.appendingPathComponent(
            CmuxGhosttyConfigPathResolver.releaseBundleIdentifier,
            isDirectory: true
        )
        try fileManager.createDirectory(at: releaseDirectory, withIntermediateDirectories: true)
        let releaseConfig = releaseDirectory.appendingPathComponent("config.ghostty")
        try "theme = release\n".write(to: releaseConfig, atomically: true, encoding: .utf8)

        let urls = resolver.loadConfigURLs(
            currentBundleIdentifier: "com.example.other",
            appSupportDirectory: root,
            fileManager: fileManager
        )

        #expect(urls.isEmpty)
    }
}
