import Foundation
import SwiftUI

@MainActor
struct ConversationSidebarProjection {
    let historyPagePerAgent = 30

    func liveSessionKey(for record: AgentChatSessionRecord) -> String {
        VaultLiveSessionKeys.key(
            kind: record.agentKind.sourceName,
            sessionID: record.hookStoreLookupSessionID
        )
    }

    func presentationAgentsByID(_ agents: [SessionAgent]) -> [String: SessionAgent] {
        var result: [String: SessionAgent] = [:]
        result.reserveCapacity(agents.count)
        for agent in agents where result[agent.rawValue] == nil {
            result[agent.rawValue] = agent
        }
        return result
    }

    func presentationAgent(
        for record: AgentChatSessionRecord,
        configuredAgentsByID: [String: SessionAgent]
    ) -> SessionAgent? {
        // This fallback is presentation-only. Session identity and routing
        // continue to come from the authoritative agent-chat record.
        configuredAgentsByID[record.agentKind.sourceName]
            ?? SessionAgent(rawValue: record.agentKind.sourceName)
    }

    func workspacesByID(_ workspaces: [Workspace]) -> [UUID: Workspace] {
        Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
    }

    func workspacesByPanelID(_ workspaces: [Workspace]) -> [UUID: Workspace] {
        var result: [UUID: Workspace] = [:]
        for workspace in workspaces {
            for panelID in workspace.panels.keys {
                result[panelID] = workspace
            }
        }
        return result
    }

    /// Both inputs are newest-first Vault snapshots. The initial snapshot wins
    /// for overlapping ids because it carries the freshest metadata; older
    /// expanded rows fill only ids that fell outside the initial preview.
    func recentHistory(
        initial: [SessionEntry],
        expanded: [SessionEntry]
    ) -> [SessionEntry] {
        var seen = Set<String>()
        let current = initial.filter { seen.insert($0.id).inserted }
        guard !expanded.isEmpty else { return current }

        var older: [SessionEntry] = []
        older.reserveCapacity(expanded.count)
        for entry in expanded where seen.insert(entry.id).inserted {
            older.append(entry)
        }

        var result: [SessionEntry] = []
        result.reserveCapacity(current.count + older.count)
        var currentIndex = 0
        var olderIndex = 0
        while currentIndex < current.count, olderIndex < older.count {
            let lhs = current[currentIndex]
            let rhs = older[olderIndex]
            if lhs.modified > rhs.modified || (lhs.modified == rhs.modified && lhs.id < rhs.id) {
                result.append(lhs)
                currentIndex += 1
            } else {
                result.append(rhs)
                olderIndex += 1
            }
        }
        result.append(contentsOf: current[currentIndex...])
        result.append(contentsOf: older[olderIndex...])
        return result
    }

    func metadataMatches(
        title: String,
        agent: SessionAgent,
        id: String,
        directory: String?,
        query: String
    ) -> Bool {
        let terms = normalized(query).split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = normalized([
            title,
            agent.displayName,
            id,
            directory ?? ""
        ].joined(separator: " "))
        return terms.allSatisfy { haystack.contains($0) }
    }

    func shouldFetchMoreHistory(
        visibleHistoryCount: Int,
        loadedHistoryCount: Int,
        searchIsEmpty: Bool,
        canLoadMoreHistory: Bool
    ) -> Bool {
        searchIsEmpty
            && canLoadMoreHistory
            && visibleHistoryCount >= loadedHistoryCount
    }

    func nextHistoryPerAgentLimit(current: Int) -> Int {
        min(current + historyPagePerAgent, SessionIndexStore.searchMaxFiles)
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
struct ConversationSidebarLiveRefreshModifier: ViewModifier {
    @Binding var revision: UInt64
    @Binding var presentationAgents: [SessionAgent]

    func body(content: Content) -> some View {
        content
            .task {
                let loaded = await SessionIndexStore.defaultAgentOrder(workingDirectory: nil)
                guard !Task.isCancelled else { return }
                presentationAgents = loaded.agents
            }
            .task {
                for await _ in NotificationCenter.default.notifications(
                    named: .agentChatSessionRecordsDidChange
                ) {
                    guard !Task.isCancelled else { return }
                    revision &+= 1
                }
            }
    }
}
