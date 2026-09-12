import AppKit
import CmuxTerminal
import Foundation
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("RPC target alias read proof", .serialized)
struct RPCTargetAliasReadProofTests {
    private struct LiveSurfaceWaitTimeout: Error {
        let surfaceID: UUID
    }

    @Test func camelCaseSurfaceAliasCannotReplayFocusedTerminal() async throws {
        try await withAppContext { workspace in
            let originalPanel = try #require(
                workspace.focusedPanelId.flatMap { workspace.panels[$0] as? TerminalPanel }
            )
            let replacement = TerminalSurface(
                id: originalPanel.id,
                tabId: workspace.id,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                configTemplate: nil,
                initialCommand: "/bin/cat"
            )
            defer {
                replacement.teardownSurface()
                GhosttyApp.terminalSurfaceRegistry.unregister(replacement)
            }

            try await waitForLiveSurface(replacement)
            let requestedSurfaceID = UUID().uuidString
            let envelope = try await socketEnvelopeUsingExecutionPolicy(
                method: "terminal.replay",
                params: ["surfaceId": requestedSurfaceID]
            )

            if envelope["ok"] as? Bool == true {
                let result = try #require(envelope["result"] as? [String: Any])
                let returnedSurfaceID = try #require(result["surface_id"] as? String)
                #expect(returnedSurfaceID != requestedSurfaceID)
                Issue.record("camelCase surfaceId silently replayed the focused terminal")
                return
            }

            let error = try #require(envelope["error"] as? [String: Any])
            #expect(error["code"] as? String == "invalid_params")
        }
    }

    @Test func trueNoTargetReplayStillUsesFocusedTerminal() async throws {
        try await withAppContext { workspace in
            let originalPanel = try #require(
                workspace.focusedPanelId.flatMap { workspace.panels[$0] as? TerminalPanel }
            )
            let replacement = TerminalSurface(
                id: originalPanel.id,
                tabId: workspace.id,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                configTemplate: nil,
                initialCommand: "/bin/cat"
            )
            defer {
                replacement.teardownSurface()
                GhosttyApp.terminalSurfaceRegistry.unregister(replacement)
            }

            try await waitForLiveSurface(replacement)
            let envelope = try await socketEnvelopeUsingExecutionPolicy(
                method: "terminal.replay",
                params: [:]
            )
            #expect(envelope["ok"] as? Bool == true)
            let result = try #require(envelope["result"] as? [String: Any])
            #expect((result["surface_id"] as? String) == replacement.id.uuidString)
        }
    }

    private func waitForLiveSurface(_ surface: TerminalSurface) async throws {
        guard !surface.hasLiveSurface else { return }
        let previousOnRuntimeReady = surface.onRuntimeReady
        defer { surface.onRuntimeReady = previousOnRuntimeReady }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                previousOnRuntimeReady?()
                continuation.yield()
                continuation.finish()
            }
        }
        if surface.hasLiveSurface { return }
        let becameReady = try await withThrowingTaskGroup(
            of: Bool.self,
            returning: Bool.self
        ) { group in
            group.addTask {
                for await _ in readiness { return true }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return false
            }
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard becameReady else {
            throw LiveSurfaceWaitTimeout(surfaceID: surface.id)
        }
    }

    private func socketEnvelopeUsingExecutionPolicy(
        method: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        let request: [String: Any] = ["id": method, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try #require(String(data: data, encoding: .utf8))
        let raw = try #require(
            await TerminalController.shared.processCommandUsingSocketExecutionPolicyAsync(line)
        )
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func withAppContext(
        _ body: @MainActor (Workspace) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            try await body(workspace)
        }
    }
}
