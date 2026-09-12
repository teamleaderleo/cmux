import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
    }
}
