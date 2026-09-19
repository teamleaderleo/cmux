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
    private let projection = ConversationSidebarProjection()

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
            projection.liveSessionKey(for: record)
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
            projection.presentationAgent(
                for: record,
                configuredAgents: [.registered(registered)]
            )
        )
        #expect(resolved == .registered(registered))
        #expect(resolved.displayName == "Pi")
        #expect(resolved.assetName == "AgentIcons/Pi")
    }

    @Test
    func expandedHistoryKeepsNewerStoreEntries() {
        let old = sessionEntry(id: "old", title: "old", modified: 10)
        let refreshed = sessionEntry(id: "same", title: "new metadata", modified: 30)
        let stale = sessionEntry(id: "same", title: "stale metadata", modified: 20)
        let olderDuplicate = sessionEntry(id: "same", title: "older duplicate", modified: 5)

        let merged = projection.recentHistory(
            initial: [refreshed],
            expanded: [old, stale, olderDuplicate]
        )
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })

        #expect(Set(byID.keys) == ["old", "same"])
        #expect(byID["same"]?.title == "new metadata")
    }

    @Test
    func deeperHistoryFetchStartsAtLoadedBoundary() {
        #expect(
            !projection.shouldFetchMoreHistory(
                visibleHistoryCount: 24,
                loadedHistoryCount: SessionIndexStore.perAgentLimit,
                searchIsEmpty: true,
                canLoadMoreHistory: true
            )
        )
        #expect(
            projection.shouldFetchMoreHistory(
                visibleHistoryCount: 48,
                loadedHistoryCount: SessionIndexStore.perAgentLimit,
                searchIsEmpty: true,
                canLoadMoreHistory: true
            )
        )
        #expect(
            projection.nextHistoryPerAgentLimit(
                current: SessionIndexStore.perAgentLimit
            ) == SessionIndexStore.perAgentLimit + projection.historyPagePerAgent
        )
        #expect(
            !projection.shouldFetchMoreHistory(
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
    private func sessionEntry(
        id: String,
        title: String,
        modified: TimeInterval
    ) -> SessionEntry {
        SessionEntry(
            id: id,
            agent: .claude,
            sessionId: id,
            title: title,
            cwd: "/Users/example/project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: modified),
            fileURL: nil,
            specifics: .claude(
                model: nil,
                permissionMode: nil,
                configDirectoryForResume: nil
            )
        )
    }
}
