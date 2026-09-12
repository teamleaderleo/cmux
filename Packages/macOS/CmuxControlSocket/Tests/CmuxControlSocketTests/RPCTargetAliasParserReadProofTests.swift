import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("RPC target alias parser read proof")
struct RPCTargetAliasParserReadProofTests {
    private let parser = ControlRequestParser()

    @Test func strictRejectsKnownTargetAliasVariants() {
        let aliases = [
            "windowId", "groupId", "workspaceId", "surfaceId",
            "terminalId", "tabId", "paneId", "surfaceID", "Surface_Id",
        ]
        for alias in aliases {
            let line = "{\"method\":\"terminal.replay\",\"params\":{\"\(alias)\":\"00000000-0000-0000-0000-000000000001\"}}"
            #expect((try? parser.request(fromLine: line).get()) == nil)
        }
    }

    @Test func strictPreservesCanonicalNoTargetAndUnrelatedExtensionKeys() {
        let canonical = #"{"method":"terminal.replay","params":{"surface_id":"00000000-0000-0000-0000-000000000001"}}"#
        let noTarget = #"{"method":"terminal.replay","params":{}}"#
        let extensionKey = #"{"method":"terminal.replay","params":{"totally_bogus_key":1}}"#
        #expect((try? parser.request(fromLine: canonical).get()) != nil)
        #expect((try? parser.request(fromLine: noTarget).get()) != nil)
        #expect((try? parser.request(fromLine: extensionKey).get()) != nil)
    }
}
