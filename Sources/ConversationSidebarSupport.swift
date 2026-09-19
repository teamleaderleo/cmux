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

    func presentationAgent(
        for record: AgentChatSessionRecord,
        configuredAgents: [SessionAgent]
    ) -> SessionAgent? {
        configuredAgents.first { $0.rawValue == record.agentKind.sourceName }
            ?? SessionAgent(rawValue: record.agentKind.sourceName)
    }

    func recentHistory(
        initial: [SessionEntry],
        expanded: [SessionEntry]
    ) -> [SessionEntry] {
        guard !expanded.isEmpty else { return initial }
        var byID = Dictionary(uniqueKeysWithValues: expanded.map { ($0.id, $0) })
        for entry in initial {
            byID[entry.id] = entry
        }
        return Array(byID.values)
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
