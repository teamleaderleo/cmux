import Darwin
import Foundation
import Testing

@testable import CmuxForeignWindows

@Suite
struct ClaudeDesktopDiagnosticsTests {
    @Test
    func testUserDataDirectoryAcceptsBothArgumentForms() {
        #expect(
            ClaudeDesktopDiagnostics.userDataDirectory(in: ["Claude", "--user-data-dir=/a b/work"])
                == "/a b/work"
        )
        #expect(
            ClaudeDesktopDiagnostics.userDataDirectory(in: ["Claude", "--user-data-dir", "/x"]) == "/x"
        )
        #expect(ClaudeDesktopDiagnostics.userDataDirectory(in: ["Claude"]) == nil)
    }

    @Test
    func testParsesProcArgsBuffer() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: Array("/bin/app".utf8) + [0, 0, 0])
        buffer.append(contentsOf: Array("app".utf8) + [0])
        buffer.append(contentsOf: Array("--user-data-dir=/p".utf8) + [0])
        buffer.append(contentsOf: Array("HOME=/Users/x".utf8) + [0])
        #expect(ProcessArgumentsReader.parse(buffer) == ["app", "--user-data-dir=/p"])
    }

    @Test
    func testReadsOwnArguments() throws {
        let arguments = try #require(ProcessArgumentsReader().arguments(of: getpid()))
        #expect(arguments.count == CommandLine.arguments.count)
    }
}
