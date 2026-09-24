import Testing

@testable import CmuxForeignWindows

@Suite
@MainActor
struct ForeignWindowYieldCoordinatorTests {
    @Test
    func testYieldCoordinatorNestsTokens() {
        let coordinator = ForeignWindowYieldCoordinator()
        let first = coordinator.beginYield(reason: "a")
        let second = coordinator.beginYield(reason: "b")
        coordinator.endYield(first)
        #expect(coordinator.isYielding)
        coordinator.endYield(second)
        coordinator.endYield(second)
        #expect(!coordinator.isYielding)
    }
}
