import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct CmuxGhosttyConfigPathResolverTests {
    private let resolver = CmuxGhosttyConfigPathResolver()

    @Test func taggedBuildFallsBackToReleaseConfig() throws {
        let appSupport = try temporaryAppSupportDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let releaseConfig = try writeConfig(
            bundleIdentifier: CmuxGhosttyConfigPathResolver.releaseBundleIdentifier,
            contents: "theme = 0x96f\n",
            appSupportDirectory: appSupport
        )

        let urls = resolver.loadConfigURLs(
            currentBundleIdentifier: "com.cmuxterm.app.terminal-kit",
            appSupportDirectory: appSupport
        )

        #expect(urls == [releaseConfig])
    }

    @Test func arbitraryReloadTagFallsBackToReleaseConfig() throws {
        let appSupport = try temporaryAppSupportDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let releaseConfig = try writeConfig(
            bundleIdentifier: CmuxGhosttyConfigPathResolver.releaseBundleIdentifier,
            contents: "selection-background = #123456\n",
            appSupportDirectory: appSupport
        )

        let urls = resolver.loadConfigURLs(
            currentBundleIdentifier: "com.cmuxterm.app.feature-xyz-lol",
            appSupportDirectory: appSupport
        )

        #expect(urls == [releaseConfig])
    }

    @Test func taggedBuildOwnConfigTakesPrecedence() throws {
        let appSupport = try temporaryAppSupportDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }

        _ = try writeConfig(
            bundleIdentifier: CmuxGhosttyConfigPathResolver.releaseBundleIdentifier,
            contents: "theme = release\n",
            appSupportDirectory: appSupport
        )
        let taggedConfig = try writeConfig(
            bundleIdentifier: "com.cmuxterm.app.terminal-kit",
            contents: "theme = terminal-kit\n",
            appSupportDirectory: appSupport
        )

        let urls = resolver.loadConfigURLs(
            currentBundleIdentifier: "com.cmuxterm.app.terminal-kit",
            appSupportDirectory: appSupport
        )

        #expect(urls == [taggedConfig])
    }

    @Test func unrelatedBundleDoesNotReadCmuxReleaseConfig() throws {
        let appSupport = try temporaryAppSupportDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }

        _ = try writeConfig(
            bundleIdentifier: CmuxGhosttyConfigPathResolver.releaseBundleIdentifier,
            contents: "theme = release\n",
            appSupportDirectory: appSupport
        )

        let urls = resolver.loadConfigURLs(
            currentBundleIdentifier: "com.example.other-app",
            appSupportDirectory: appSupport
        )

        #expect(urls.isEmpty)
    }

    private func temporaryAppSupportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func writeConfig(
        bundleIdentifier: String,
        contents: String,
        appSupportDirectory: URL
    ) throws -> URL {
        let directory = appSupportDirectory
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("config.ghostty", isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
