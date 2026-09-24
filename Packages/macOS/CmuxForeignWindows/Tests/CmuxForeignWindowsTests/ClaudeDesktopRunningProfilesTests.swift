import Darwin
import Foundation
import Testing

@testable import CmuxForeignWindows

@Suite
struct ClaudeDesktopRunningProfilesTests {
    private let store = ClaudeDesktopProfileStore(
        rootURL: URL(fileURLWithPath: "/Users/tester/profiles", isDirectory: true)
    )

    @Test
    func testMapsProfileInstancesAndIgnoresOthers() {
        let result = ClaudeDesktopRunningProfiles.profiles(
            in: [
                10: ["Claude", "--user-data-dir=/Users/tester/profiles/work"],
                11: ["Claude", "--user-data-dir", "/Users/tester/profiles/personal/"],
                12: ["Claude"],
                13: ["Claude", "--user-data-dir=/elsewhere/work"],
                14: ["Claude", "--user-data-dir=/Users/tester/profiles/Not Normal"],
                15: ["Claude", "--user-data-dir=/Users/tester/profiles/work/nested"],
            ],
            store: store
        )
        #expect(result == ["work": 10, "personal": 11])
    }

    @Test
    func testDuplicateProfileKeepsLowestProcess() {
        let result = ClaudeDesktopRunningProfiles.profiles(
            in: [
                30: ["Claude", "--user-data-dir=/Users/tester/profiles/work"],
                20: ["Claude", "--user-data-dir=/Users/tester/profiles/work"],
            ],
            store: store
        )
        #expect(result == ["work": 20])
    }
}
