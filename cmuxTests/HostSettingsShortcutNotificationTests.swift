import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Host settings shortcut notifications", .serialized)
struct HostSettingsShortcutNotificationTests {
    @Test
    func changedSettingsFilePostsOneShortcutNotification() throws {
        try withSettingsFile(
            initialContents: #"{"shortcuts":{"openBrowser":"cmd+b"}}"#,
            updatedContents: #"{"shortcuts":{"openBrowser":"cmd+n"}}"#,
            expectedNotificationCount: 1
        )
    }

    @Test
    func unchangedSettingsFileStillPostsOneShortcutNotification() throws {
        let contents = #"{"shortcuts":{"openBrowser":"cmd+b"}}"#
        try withSettingsFile(
            initialContents: contents,
            updatedContents: contents,
            expectedNotificationCount: 1
        )
    }

    private func withSettingsFile(
        initialContents: String,
        updatedContents: String,
        expectedNotificationCount: Int
    ) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-host-shortcut-notifications-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try initialContents.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        defer { KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore }

        let counter = ShortcutChangeNotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.object as? URL == settingsFileURL else { return }
            counter.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try updatedContents.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        HostSettingsActions(
            configFileURL: settingsFileURL,
            computerUseRuntimeService: ComputerUseRuntimeService()
        ).notifyShortcutSettingsDidChange()

        #expect(counter.value == expectedNotificationCount)
    }
}

@MainActor
@Suite("Computer Use cross-generation identity")
struct ComputerUseCrossGenerationIdentityTests {
    @Test
    func delayedGenerationACompletionCannotResolveGenerationBWithSameLogicalSession() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let logicalAgentSessionID = "stable-agent-session"

        let generationA = Process()
        generationA.executableURL = URL(fileURLWithPath: "/bin/sleep")
        generationA.arguments = ["30"]
        try generationA.run()
        let generationAProcessID = Int(generationA.processIdentifier)
        generationA.terminate()
        generationA.waitUntilExit()

        let generationBProcessID = ProcessInfo.processInfo.processIdentifier
        let generationBIdentity = try #require(
            AgentPIDProcessIdentity(pid: generationBProcessID)
        )
        let entry = RestorableAgentSessionIndex.Entry(
            snapshot: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: logicalAgentSessionID
            ),
            lifecycle: .running,
            updatedAt: Date().timeIntervalSince1970,
            processLiveness: .running,
            hasRecordedProcessID: true,
            processIDs: [Int(generationBProcessID)],
            processIdentities: [Int(generationBProcessID): generationBIdentity],
            agentProcessIDs: [Int(generationBProcessID)],
            agentProcessIdentities: [Int(generationBProcessID): generationBIdentity],
            hibernationPanelProcessIDs: [],
            terminationProcessIDs: [],
            terminationProcessIdentities: [:],
            containsUnrelatedProcess: false
        )
        let projection = ComputerUseLiveSessionProjection(
            liveEntries: {
                [(
                    panelKey: RestorableAgentSessionIndex.PanelKey(
                        workspaceId: workspaceID,
                        panelId: surfaceID
                    ),
                    entry: entry
                )]
            },
            scheduleRefreshIfStale: {}
        )
        let expectedDriverSessionID = ComputerUseSessionScope.driverSessionID(
            surfaceID: surfaceID
        )

        #expect(projection.driverSessionID(
            surfaceID: surfaceID.uuidString,
            agentSessionID: logicalAgentSessionID,
            hookProcessID: Int(generationBProcessID)
        ) == expectedDriverSessionID)
        #expect(projection.driverSessionID(
            surfaceID: surfaceID.uuidString,
            agentSessionID: "hook-protocol-alias",
            hookProcessID: Int(generationBProcessID)
        ) == expectedDriverSessionID)
        #expect(projection.driverSessionID(
            surfaceID: surfaceID.uuidString,
            agentSessionID: logicalAgentSessionID,
            hookProcessID: generationAProcessID
        ) == nil)
        #expect(projection.driverSessionID(
            surfaceID: surfaceID.uuidString,
            agentSessionID: logicalAgentSessionID
        ) == expectedDriverSessionID)

        let staleReusedPIDIdentity = AgentPIDProcessIdentity(
            pid: generationBIdentity.pid,
            startSeconds: generationBIdentity.startSeconds - 1,
            startMicroseconds: generationBIdentity.startMicroseconds
        )
        #expect(projection.driverSessionID(
            surfaceID: surfaceID.uuidString,
            agentSessionID: logicalAgentSessionID,
            hookProcessID: Int(generationBProcessID),
            hookProcessIdentity: generationBIdentity
        ) == expectedDriverSessionID)
        #expect(projection.driverSessionID(
            surfaceID: surfaceID.uuidString,
            agentSessionID: logicalAgentSessionID,
            hookProcessID: Int(generationBProcessID),
            hookProcessIdentity: staleReusedPIDIdentity
        ) == nil)

        let invocationAt = Date(timeIntervalSince1970: 100)
        let completion = WorkstreamEvent(
            sessionId: logicalAgentSessionID,
            hookEventName: .stop,
            source: "codex",
            surfaceId: surfaceID.uuidString,
            ppid: Int(generationBProcessID),
            receivedAt: Date(timeIntervalSince1970: 101)
        )
        let acceptedInvocation = ComputerUseAcceptedInvocationIdentity(
            surfaceID: surfaceID,
            agentSessionID: logicalAgentSessionID,
            processIdentity: generationBIdentity,
            receivedAt: invocationAt
        )
        #expect(acceptedInvocation.matchesCompletion(
            completion,
            processIdentity: generationBIdentity
        ))
        #expect(!acceptedInvocation.matchesCompletion(
            completion,
            processIdentity: staleReusedPIDIdentity
        ))

        let ingressEvent = WorkstreamEvent(
            sessionId: logicalAgentSessionID,
            hookEventName: .preToolUse,
            source: "codex",
            surfaceId: surfaceID.uuidString,
            ppid: Int(generationBProcessID)
        )
        let ingressGeneration = try #require(
            ingressEvent.feedIngressProcessGenerationEvent
        )
        #expect(ingressGeneration.processIdentity == generationBIdentity)
    }
}

private final class ShortcutChangeNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
