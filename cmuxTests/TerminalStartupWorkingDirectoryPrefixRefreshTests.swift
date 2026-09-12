import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Persisted restore working directory refresh")
struct TerminalStartupWorkingDirectoryPrefixRefreshTests {
    @Test
    func missingPersistedWorkingDirectoryFailsClosed() throws {
        let inherited = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fieldwork-inherited-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inherited, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inherited) }
        let missing = inherited.appendingPathComponent("removed-saved-repository").path
        let marker = inherited.appendingPathComponent("payload-ran")
        let command = TerminalStartupWorkingDirectoryPrefix.prefix(
            "printf payload > \(shellQuote(marker.path))",
            workingDirectory: missing
        )
        let status = try runShell(command, cwd: inherited)
        #expect(status != 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func existingPersistedWorkingDirectoryRunsThereWithQuotedPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fieldwork-cwd-\(UUID().uuidString)", isDirectory: true)
        let saved = root.appendingPathComponent("repo with ' quote", isDirectory: true)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("pwd")
        let command = TerminalStartupWorkingDirectoryPrefix.prefix(
            "pwd > \(shellQuote(marker.path))",
            workingDirectory: saved.path
        )
        #expect(try runShell(command, cwd: root) == 0)
        let observed = try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(observed == saved.path)
    }

    @Test
    func optionalPlacementRetainsFallbackSemantics() throws {
        let inherited = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fieldwork-optional-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inherited, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inherited) }
        let missing = inherited.appendingPathComponent("missing-optional-directory").path
        let marker = inherited.appendingPathComponent("optional-pwd")
        let prefix = try #require(
            TerminalStartupWorkingDirectoryPrefix.optionalChangeDirectoryPrefix(for: missing)
        )
        #expect(try runShell(prefix + "pwd > \(shellQuote(marker.path))", cwd: inherited) == 0)
        let observed = try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(observed == inherited.path)
    }

    @Test
    func requiredPrefixKeepsFishCompatibleAndNushellDelegatedSyntax() {
        let posix = TerminalStartupWorkingDirectoryPrefix.prefix(
            "'claude' '--resume' 'SID'",
            workingDirectory: "/tmp/repo"
        )
        #expect(!posix.contains("{"))
        #expect(posix.contains(" 2>/dev/null && "))
        #expect(!posix.contains("[ ! -d"))
        let typed = TerminalStartupTypedShellCommand(dialect: .nushell)
            .typedInput(posixCommand: posix)
        #expect(typed.hasPrefix("^/bin/sh -c "))
    }

    @Test
    func requiredPrefixRetargetsWithoutStackingOldDirectory() {
        let old = "/tmp/cmux-old-repository"
        let new = "/tmp/cmux-new-repository"
        let original = TerminalStartupWorkingDirectoryPrefix.prefix(
            "'claude' '--resume' 'SID'",
            workingDirectory: old
        )
        let retargeted = TerminalStartupWorkingDirectoryPrefix.replacingRequiredChangeDirectoryPrefix(
            in: original,
            previousWorkingDirectory: old,
            workingDirectory: new
        )
        #expect(retargeted == "cd -- '/tmp/cmux-new-repository' 2>/dev/null && 'claude' '--resume' 'SID'")
        #expect(!retargeted.contains(old))
    }

    private func runShell(_ command: String, cwd: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = cwd
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
