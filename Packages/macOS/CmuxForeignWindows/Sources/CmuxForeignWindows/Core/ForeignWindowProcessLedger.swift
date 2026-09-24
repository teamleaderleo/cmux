public import Darwin

/// Process identifiers of the external applications this host launched.
///
/// Every ``ForeignWindowSession`` built with a ledger records its process here
/// while it runs. A host that does not launch through sessions, such as a
/// launcher that tracks instances started elsewhere, reports its set with
/// ``reconcile(_:)``. Consumers such as ``ClaudeDesktopLinkRouter`` use it to tell
/// pane-owned instances from the user's own.
@MainActor
public final class ForeignWindowProcessLedger {
    /// Processes launched by sessions and still believed to be running.
    public private(set) var ownedProcessIdentifiers: Set<pid_t> = []

    /// Called after ``ownedProcessIdentifiers`` changes, with the new value.
    public var onChange: (@MainActor (Set<pid_t>) -> Void)?

    /// Creates an empty ledger.
    public init() {}

    /// Replaces one owned process with another in a single change.
    ///
    /// A session that swaps processes reports once, so observers never see a
    /// transient empty set between the old and new process.
    func replace(_ oldProcess: pid_t?, with newProcess: pid_t?) {
        var next = ownedProcessIdentifiers
        if let oldProcess { next.remove(oldProcess) }
        if let newProcess { next.insert(newProcess) }
        guard next != ownedProcessIdentifiers else { return }
        ownedProcessIdentifiers = next
        onChange?(next)
    }

    /// Replaces the whole owned set, reporting once if it changed.
    ///
    /// - Parameter processIdentifiers: Every process the host now owns.
    public func reconcile(_ processIdentifiers: Set<pid_t>) {
        guard processIdentifiers != ownedProcessIdentifiers else { return }
        ownedProcessIdentifiers = processIdentifiers
        onChange?(processIdentifiers)
    }
}
