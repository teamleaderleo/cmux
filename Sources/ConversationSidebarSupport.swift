import Combine
import Foundation

enum ConversationSidebarProjection {
    static let historyPagePerAgent = 30

    static func liveSessionKey(for record: AgentChatSessionRecord) -> String {
        VaultLiveSessionKeys.key(
            kind: record.agentKind.sourceName,
            sessionID: record.hookStoreLookupSessionID
        )
    }

    static func presentationAgent(
        for record: AgentChatSessionRecord,
        configuredAgents: [SessionAgent]
    ) -> SessionAgent? {
        configuredAgents.first { $0.rawValue == record.agentKind.sourceName }
            ?? SessionAgent(rawValue: record.agentKind.sourceName)
    }

    static func shouldFetchMoreHistory(
        visibleHistoryCount: Int,
        loadedHistoryCount: Int,
        searchIsEmpty: Bool,
        canLoadMoreHistory: Bool
    ) -> Bool {
        searchIsEmpty
            && canLoadMoreHistory
            && visibleHistoryCount >= loadedHistoryCount
    }

    static func nextHistoryPerAgentLimit(current: Int) -> Int {
        min(current + historyPagePerAgent, SessionIndexStore.searchMaxFiles)
    }
}

@MainActor
final class ConversationSidebarLiveState: ObservableObject {
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var presentationAgents: [SessionAgent] = []

    private var recordChanges: AnyCancellable?

    init() {
        recordChanges = NotificationCenter.default
            .publisher(for: .agentChatSessionRecordsDidChange)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.revision &+= 1
                }
            }

        Task { @MainActor [weak self] in
            let loaded = await SessionIndexStore.defaultAgentOrder(workingDirectory: nil)
            guard !Task.isCancelled else { return }
            self?.presentationAgents = loaded.agents
        }
    }
}
