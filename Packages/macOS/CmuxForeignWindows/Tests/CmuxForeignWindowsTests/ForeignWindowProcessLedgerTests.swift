import Darwin
import Testing

@testable import CmuxForeignWindows

@Suite
@MainActor
struct ForeignWindowProcessLedgerTests {
    @Test
    func testReplaceReportsOnceWithoutTransientEmptySet() {
        let ledger = ForeignWindowProcessLedger()
        var reports: [Set<pid_t>] = []
        ledger.onChange = { reports.append($0) }

        ledger.replace(nil, with: 10)
        ledger.replace(10, with: 11)
        ledger.replace(11, with: 11)
        ledger.replace(11, with: nil)

        #expect(reports == [[10], [11], []])
        #expect(ledger.ownedProcessIdentifiers.isEmpty)
    }

    @Test
    func testReconcileReportsOnlyChanges() {
        let ledger = ForeignWindowProcessLedger()
        var reports: [Set<pid_t>] = []
        ledger.onChange = { reports.append($0) }

        ledger.reconcile([10, 11])
        ledger.reconcile([11, 10])
        ledger.reconcile([])

        #expect(reports == [[10, 11], []])
    }
}
