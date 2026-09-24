import Testing

@testable import CmuxForeignWindows

@Suite
struct ClaudeDesktopProfileNameTests {
    @Test(arguments: [
        ("../Personal Acct", "personal-acct"),
        ("  ", "default"),
        ("Work_2.b", "work_2.b"),
        ("--.x.--", "x")
    ] as [(String, String)])
    func testNormalizesToStableDirectoryComponent(raw: String, expected: String) {
        #expect(ClaudeDesktopProfileName(raw).rawValue == expected)
    }

    @Test
    func testNilIsDefault() {
        #expect(ClaudeDesktopProfileName(nil).rawValue == "default")
        #expect(ClaudeDesktopProfileName.isNormalized("work"))
        #expect(!ClaudeDesktopProfileName.isNormalized("Work"))
    }
}
