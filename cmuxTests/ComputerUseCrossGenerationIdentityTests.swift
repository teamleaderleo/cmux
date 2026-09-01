import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Computer Use cross-generation identity")
struct ComputerUseCrossGenerationIdentityTests {
    @Test @MainActor
    func delayedGenerationACompletionCannotResolveGenerationBWithSameLogicalSession() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let logicalAgentSessionID = "stable-agent-session"

        // Generation A is a real process that has already retired before the
        // delayed hook is resolved.
        let generationA = Process()
        generationA.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try generationA.run()
        let generationAProcessID = Int(generationA.processIdentifier)
        generationA.waitUntilExit()
        #expect(generationA.terminationStatus == 0)

        // Generation B owns the live projection while retaining the same
        // logical agent session id, matching resume semantics.
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

        // Current B is accepted.
        #expect(projection.driverSessionID(
            surfaceID: surfaceID.uuidString,
            agentSessionID: logicalAgentSessionID,
            hookProcessID: Int(generationBProcessID)
        ) == expectedDriverSessionID)

        // An aliasing hook protocol id remains accepted when its exact process
        // generation belongs to current B.
        #expect(projection.driverSessionID(
            surfaceID: surfaceID.uuidString,
            agentSessionID: "hook-protocol-alias",
            hookProcessID: Int(generationBProcessID)
        ) == expectedDriverSessionID)

        // A delayed completion from retired A must fail even though A and B
        // intentionally share the same durable logical agent session id.
        #expect(projection.driverSessionID(
            surfaceID: surfaceID.uuidString,
            agentSessionID: logicalAgentSessionID,
            hookProcessID: generationAProcessID
        ) == nil)

        // Compatibility fallback remains available to hook sources that carry
        // no process id at all.
        #expect(projection.driverSessionID(
            surfaceID: surfaceID.uuidString,
            agentSessionID: logicalAgentSessionID
        ) == expectedDriverSessionID)
    }
}
