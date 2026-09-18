import Foundation
import Observation
import CmuxSwiftRender

/// Shared metadata, independent of each window's filter/search/selection.
@MainActor @Observable
final class ConversationHistoryStore {
    static let shared = ConversationHistoryStore()
    var rows: SwiftValue = .array([])
    var error: String?
    private var refreshing = false
    private var lastRefresh = Date.distantPast

    func refresh() async {
        guard !refreshing, Date().timeIntervalSince(lastRefresh) > 29 else { return }
        refreshing = true
        let result = await Task.detached(priority: .utility) { ConversationHistoryReader.read() }.value
        switch result {
        case .success(let value):
            if rows != value { rows = value }
            if error != nil { error = nil }
        case .failure: error = "Conversation history couldn't refresh. Showing the last available history."
        }
        lastRefresh = Date()
        refreshing = false
    }
}

struct ConversationHistoryReader {
    enum ReadError: Error { case unavailable, failed, malformed }
    static func read() -> Result<SwiftValue, ReadError> {
        let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/terminal-kit")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .failure(.unavailable) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-history-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: output) else { return .failure(.failed) }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["recent", "--json"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [NSHomeDirectory()+"/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = environment
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .failure(.failed) }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0,
              let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 4_000_000, let data = try? Data(contentsOf: output) else { return .failure(.failed) }
        return decode(data)
    }

    static func decode(_ data: Data) -> Result<SwiftValue, ReadError> {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return .failure(.malformed) }
        let values: [SwiftValue] = rows.compactMap { row in
            guard let provider = row["provider"] as? String, ["Claude", "Codex", "OpenCode"].contains(provider),
                  let id = row["id"] as? String, !id.isEmpty,
                  let cwd = row["cwd"] as? String, cwd.hasPrefix("/"),
                  row["title"] is String, row["updated"] is NSNumber else { return nil }
            var result: [String: SwiftValue] = [:]
            for (key, value) in row {
                if let value = value as? String { result[key] = .string(value) }
                else if let value = value as? NSNumber {
                    result[key] = CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .double(value.doubleValue)
                }
            }
            return .object(result)
        }
        return .success(.array(values))
    }
}
