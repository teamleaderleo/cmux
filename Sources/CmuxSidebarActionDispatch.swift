import AppKit
import CmuxSwiftRender
import CmuxSwiftRenderUI
import Foundation
import SwiftUI

/// Serial lane for in-process `cmux(...)` sidebar actions. Worker-lane methods
/// (browser JS, waits) must run off the main actor: on the main actor they
/// starve SwiftUI and deadlock on a not-yet-mounted webview, which is exactly
/// why they were moved off the main-actor dispatch path. Running the whole
/// action on one serial queue keeps every command in its authored order, so a
/// later command can't finish before an earlier browser navigate/click/wait.
private let cmuxSidebarWorkerQueue = DispatchQueue(label: "com.cmux.sidebar-action-worker")

/// Select-burst coalescing lives in ``SidebarSelectCoalescer``
/// (CmuxSwiftRenderUI), where its FIFO/newest-wins semantics are unit-tested.
private let sidebarSelectCoalescer = SidebarSelectCoalescer()

// The custom-sidebar rendering, interpreter, JSON DSL, resizable split, and
// the file-watching model now live in the `CmuxSwiftRender` (logic) and
// `CmuxSwiftRenderUI` (SwiftUI) packages. The app target keeps only the
// cmux-coupled action dispatch, the one piece that must reach
// `TerminalController`, and injects it into the package's view from
// `ContentView`.

/// Builds the action sink that runs interpreted sidebar buttons against the
/// live cmux command dispatcher.
///
/// `cmux(...)` commands run in-process through
/// `TerminalController.handleSocketLine(_:)` (the same worker-aware surface the
/// socket CLI uses); `log` is a debug-only no-op for now.
@MainActor
func makeCmuxSidebarActionDispatch() -> SidebarActionDispatch {
    SidebarActionDispatch(perform: { action in
        // Capture the controller on the main actor, then run the whole command
        // sequence on the serial worker queue so the commands keep their authored
        // order. handleSocketLine runs worker-lane methods (browser JS, waits) on
        // this thread and hops main-actor methods back to the main actor itself,
        // so nothing here blocks SwiftUI and ordering is preserved end to end.
        let controller = TerminalController.shared
        let commands = action.commands
        let selectGeneration = sidebarSelectCoalescer.generation(for: commands)
        return await withCheckedContinuation { continuation in
            // Existing serial lane preserves command order and keeps socket work off the main actor.
            cmuxSidebarWorkerQueue.async {
                // A newer select is already queued behind this one: skip the heavy
                // switch, the burst's final click defines the end state.
                if let selectGeneration, !sidebarSelectCoalescer.isCurrent(selectGeneration) {
                    continuation.resume(returning: true)
                    return
                }
                // Resolve immediately before dispatch, against every live window. This
                // also catches a session opened after the sidebar's last context tick.
                let resolution = DispatchQueue.main.sync {
                    Result { try commands.flatMap(reuseOpenConversation) }
                }
                guard case let .success(resolved) = resolution else {
                    continuation.resume(returning: false)
                    return
                }
                var accepted = true
                for command in resolved {
                    switch command {
                    case let .cmux(method, params):
                        var payload: [String: Any] = ["method": method, "id": UUID().uuidString]
                        if !params.isEmpty {
                            // Params arrive as strings; coerce integer-looking values
                            // (e.g. a reorder `index`) to numbers so typed v2 params
                            // like v2Int decode them.
                            var typed: [String: Any] = [:]
                            for (key, value) in params {
                                if let intValue = Int(value) {
                                    typed[key] = intValue
                                } else if value.hasPrefix("["),
                                          let data = value.data(using: .utf8),
                                          let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
                                    // Array-typed v2 params (e.g. child_workspace_ids)
                                    // travel as JSON strings through the string-only
                                    // action pipe; inflate them here.
                                    typed[key] = array
                                } else {
                                    typed[key] = value
                                }
                            }
                            payload["params"] = typed
                        }
                        guard let data = try? JSONSerialization.data(withJSONObject: payload),
                              let line = String(data: data, encoding: .utf8) else { accepted = false; continue }
                        let response = controller.handleSocketLine(line)
                        let object = response.data(using: .utf8).flatMap {
                            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                        }
                        // An unreadable response is ambiguous; never release a launch claim on that basis.
                        if object?["ok"] as? Bool == false { accepted = false }
                    case let .openURL(urlString):
                        // NSWorkspace.open is main-only; run it synchronously to keep the
                        // command's position in the sequence.
                        if let url = URL(string: urlString) {
                            DispatchQueue.main.sync { _ = NSWorkspace.shared.open(url) }
                        }
                    case .log:
                        break
                    }
                }
                continuation.resume(returning: accepted)
            }
        }
    })
}

private enum ConversationDispatchError: Error { case rejected }

/// Resume actions carry an exact provider/session identity. Reuse its live
/// terminal across windows before allocating another provider process.
@MainActor
private func reuseOpenConversation(_ command: ActionCommand) throws -> [ActionCommand] {
    guard case let .cmux(method, params) = command, method == "workspace.create",
          let description = params["description"], description.hasPrefix("tk-history:"),
          let app = AppDelegate.shared else { return [command] }
    let identity = String(description.dropFirst("tk-history:".count))
    guard let colon = identity.firstIndex(of: ":") else { return [command] }
    let provider = String(identity[..<colon])
    let session = String(identity[identity.index(after: colon)...])
    guard ["Claude", "Codex", "OpenCode"].contains(provider), !session.isEmpty else { return [command] }
    func sameSession(_ other: String) -> Bool {
        provider == "OpenCode" ? other == session : other.lowercased() == session.lowercased()
    }
    func actions(window: UUID, workspace: UUID, surface: UUID?) -> [ActionCommand] {
        var result: [ActionCommand] = [.cmux(method: "workspace.select", params: [
            "window_id": window.uuidString, "workspace_id": workspace.uuidString
        ])]
        if let surface {
            result.append(.cmux(method: "surface.focus", params: [
                "window_id": window.uuidString, "workspace_id": workspace.uuidString,
                "surface_id": surface.uuidString
            ]))
        }
        result.append(.cmux(method: "window.focus", params: ["window_id": window.uuidString]))
        return result
    }
    // Prefer an authoritative agent binding over a saved resume marker.
    var fallback: [ActionCommand]?
    let contexts = app.mainWindowContexts.values.sorted {
        ($0.windowId.uuidString == params["window_id"] ? 0 : 1,
         $0.windowId.uuidString) <
        ($1.windowId.uuidString == params["window_id"] ? 0 : 1,
         $1.windowId.uuidString)
    }
    for context in contexts where context.window != nil {
        for workspace in context.tabManager.tabs {
            let snapshot = workspace.customSidebarWorkspaceSnapshot(
                index: 0, selectedId: context.tabManager.selectedTabId, unreadCount: 0
            )
            for agent in snapshot.agents where agent.kind.lowercased().contains(provider.lowercased()) && sameSession(agent.sessionId) {
                guard let panel = agent.panelId,
                      let surface = snapshot.surfaces.first(where: { $0.panelId == panel }) else { continue }
                return actions(window: context.windowId, workspace: workspace.id,
                               surface: surface.panelId)
            }
            if fallback == nil, snapshot.customDescription == description, !snapshot.surfaces.isEmpty {
                let matches = snapshot.surfaces.filter {
                    $0.title.components(separatedBy: " | ").contains(params["title"] ?? "")
                }
                if matches.count == 1 {
                    fallback = actions(window: context.windowId, workspace: workspace.id, surface: matches[0].panelId)
                }
            }
        }
    }
    if let fallback { return fallback }
    // The conversation library opens into the selected workspace's active tile.
    // Native drop handling owns both launch metadata and live-surface reuse.
    if params["conversation_placement"] == "tab",
       let context = contexts.first(where: { $0.windowId.uuidString == params["window_id"] }),
       let selectedID = context.tabManager.selectedTabId,
       let workspace = context.tabManager.tabs.first(where: { $0.id == selectedID }),
       let panelID = workspace.focusedPanelId,
       let pane = workspace.paneId(forPanelId: panelID),
       let entry = ConversationSidebarDragSource.makeEntry(provider: provider, sessionID: session,
           title: params["title"] ?? "", directory: params["working_directory"] ?? "") {
        guard workspace.handleSessionDrop(entry: entry, destination: .insert(targetPane: pane, targetIndex: nil)) else {
            throw ConversationDispatchError.rejected
        }
        return []
    }
    return [command]
}

/// Hosts the existing native session drag source over a conversation library row.
struct ConversationSidebarDragSource: View {
    let provider: String
    let sessionID: String
    let title: String
    let directory: String
    let activate: @MainActor () -> Void
    @Environment(\.sessionDragRegistry) private var registry
    @Environment(\.tabDragTransferRegistry) private var transferRegistry
    @State private var coordinator = SessionDragCoordinator()

    private var entry: SessionEntry? {
        Self.makeEntry(provider: provider, sessionID: sessionID, title: title, directory: directory)
    }

    static func makeEntry(provider: String, sessionID: String, title: String, directory: String) -> SessionEntry? {
        let agent: SessionAgent
        let specifics: AgentSpecifics
        switch provider {
        case "Claude":
            agent = .claude
            specifics = .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
        case "Codex":
            agent = .codex
            specifics = .codex(model: nil, approvalPolicy: nil, sandboxMode: nil, effort: nil)
        case "OpenCode":
            agent = .opencode
            specifics = .opencode(providerModel: nil, agentName: nil)
        default: return nil
        }
        guard !sessionID.isEmpty, directory.hasPrefix("/") else { return nil }
        return SessionEntry(id: provider + ":" + sessionID, agent: agent, sessionId: sessionID,
                            title: title, cwd: directory, gitBranch: nil, pullRequest: nil,
                            modified: .distantPast, fileURL: nil, specifics: specifics)
    }

    var body: some View {
        if let entry, let registry, let transferRegistry {
            SessionDragSource(entry: entry, beginDrag: { entry, view, event, frame, image in
                coordinator.beginSessionDrag(entry, registry: registry,
                    tabDragTransferRegistry: transferRegistry, from: view,
                    event: event, frame: frame, image: image)
            }, onDoubleClick: activate, activatesOnSingleClick: true)
        }
    }
}
