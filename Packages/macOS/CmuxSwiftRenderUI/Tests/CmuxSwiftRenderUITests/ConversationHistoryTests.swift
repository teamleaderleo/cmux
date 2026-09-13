import Foundation
import Testing
import CmuxSwiftRender
@testable import CmuxSwiftRenderUI

struct ConversationHistoryTests {
    @Test func decodesMetadataWithoutLosingPinTypes() throws {
        let json = #"[{"provider":"OpenCode","id":"ses_abc","cwd":"/project","title":"Hello","updated":20.5,"pinned":true,"canonical_folder":"/project"}]"#
        let value = try ConversationHistoryReader.decode(Data(json.utf8)).get()
        let row = try #require(value.iterationValues?.first)
        #expect(row.member("pinned") == .bool(true))
        #expect(row.member("updated") == .double(20.5))
        #expect(row.member("canonical_folder") == .string("/project"))
    }
    @Test func ignoresMalformedRowsAndRejectsNonArrayPayloads() throws {
        let value = try ConversationHistoryReader.decode(Data(#"[{"provider":"unknown"},{"provider":"Claude","id":"a","cwd":"relative","title":"A","updated":1}]"#.utf8)).get()
        #expect(value == .array([]))
        if case .success = ConversationHistoryReader.decode(Data("{}".utf8)) {
            Issue.record("A malformed feed must not replace the previous history")
        }
    }
}
