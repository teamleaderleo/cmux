import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct ConversationSidebarRegressionTests {
    @Test
    func pendingClaudeAliasDeduplicatesAgainstHistoryIdentity() {
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        var record = AgentChatSessionRecord(
            sessionID: pendingID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 10),
            title: "Live conversation",
            pid: nil
        )
        record.rememberHookStoreSessionID(realSessionID)

        #expect(
            ConversationSidebarProjection.liveSessionKey(for: record)
                == VaultLiveSessionKeys.key(kind: "claude", sessionID: realSessionID)
        )
    }

    @Test
    func registeredAgentKeepsConfiguredPresentation() throws {
        let registered = RegisteredSessionAgent(
            id: "pi",
            name: "Pi",
            iconAssetName: "AgentIcons/Pi"
        )
        let record = AgentChatSessionRecord(
            sessionID: "pi-session",
            agentKind: .other("pi"),
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 10),
            title: nil,
            pid: nil
        )

        let resolved = try #require(
            ConversationSidebarProjection.presentationAgent(
                for: record,
                configuredAgents: [.registered(registered)]
            )
        )
        #expect(resolved == .registered(registered))
        #expect(resolved.displayName == "Pi")
        #expect(resolved.assetName == "AgentIcons/Pi")
    }

    @Test
    func deeperHistoryFetchStartsAtLoadedBoundary() {
        #expect(
            !ConversationSidebarProjection.shouldFetchMoreHistory(
                visibleHistoryCount: 24,
                loadedHistoryCount: SessionIndexStore.perAgentLimit,
                searchIsEmpty: true,
                canLoadMoreHistory: true
            )
        )
        #expect(
            ConversationSidebarProjection.shouldFetchMoreHistory(
                visibleHistoryCount: 48,
                loadedHistoryCount: SessionIndexStore.perAgentLimit,
                searchIsEmpty: true,
                canLoadMoreHistory: true
            )
        )
        #expect(
            ConversationSidebarProjection.nextHistoryPerAgentLimit(
                current: SessionIndexStore.perAgentLimit
            ) == SessionIndexStore.perAgentLimit + ConversationSidebarProjection.historyPagePerAgent
        )
        #expect(
            !ConversationSidebarProjection.shouldFetchMoreHistory(
                visibleHistoryCount: 48,
                loadedHistoryCount: SessionIndexStore.perAgentLimit,
                searchIsEmpty: false,
                canLoadMoreHistory: true
            )
        )
    }

    @Test
    func recordChangesPublishSidebarRefreshNotification() async {
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in }
        )
        let sessionID = "sidebar-refresh-session"
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            cwd: "/Users/example/project",
            receivedAt: Date(timeIntervalSince1970: 10)
        ))

        await confirmation("agent chat record update refreshes local projections") { refreshed in
            let observer = NotificationCenter.default.addObserver(
                forName: .agentChatSessionRecordsDidChange,
                object: service,
                queue: nil
            ) { _ in
                refreshed()
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            service.registry.update(sessionID: sessionID) {
                $0.title = "Updated title"
                $0.lastActivityAt = Date(timeIntervalSince1970: 20)
            }
        }
    }
}
