#if DEBUG
import Foundation

/// Merges Cmd-click fixture state into the JSON manifest consumed by UI tests.
final class TerminalCmdClickUITestManifestWriter {
    func write(updates: [String: Any], at path: String) {
        let url = URL(fileURLWithPath: path)
        var payload: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = object
        }
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            cmuxDebugLog("cmdclick.ui.write skip reason=json path=\(path)")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            cmuxDebugLog("cmdclick.ui.write error path=\(path) error=\(error.localizedDescription)")
        }
    }
}
#endif
