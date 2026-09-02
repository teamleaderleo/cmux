internal import Foundation

private let remoteDaemonEventDeliveryDrainBatchSize = 16

struct RemoteDaemonEventDeliveryLimits: Sendable {
    static let proxy = RemoteDaemonEventDeliveryLimits(
        maxPendingBytes: 96 * 1024 * 1024,
        maxPendingEvents: 65_536
    )
    static let pty = RemoteDaemonEventDeliveryLimits(
        maxPendingBytes: 16 * 1024 * 1024,
        maxPendingEvents: 16_384
    )

    let maxPendingBytes: Int
    let maxPendingEvents: Int
}

final class RemoteDaemonEventDeliveryBudget: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let pendingBytes: Int
        let pendingEvents: Int
    }

    static let shared = RemoteDaemonEventDeliveryBudget(
        maxPendingBytes: 128 * 1024 * 1024,
        maxPendingEvents: 131_072
    )

    private let lock = NSLock()
    private let maxPendingBytes: Int
    private let maxPendingEvents: Int
    private var pendingBytes = 0
    private var pendingEvents = 0

    init(maxPendingBytes: Int, maxPendingEvents: Int) {
        self.maxPendingBytes = max(0, maxPendingBytes)
        self.maxPendingEvents = max(0, maxPendingEvents)
    }

    func reserve(bytes: Int) -> Bool {
        guard bytes >= 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard pendingEvents < maxPendingEvents else { return false }
        guard pendingBytes <= maxPendingBytes else { return false }
        guard bytes <= maxPendingBytes - pendingBytes else { return false }
        pendingEvents += 1
        pendingBytes += bytes
        return true
    }

    func release(bytes: Int, events: Int = 1) {
        guard bytes >= 0, events >= 0 else { return }
        lock.lock()
        pendingBytes = max(0, pendingBytes - bytes)
        pendingEvents = max(0, pendingEvents - events)
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(pendingBytes: pendingBytes, pendingEvents: pendingEvents)
    }
}

final class RemoteDaemonEventDeliveryQueue<Event: Sendable>: @unchecked Sendable {
    enum EnqueueResult {
        case enqueued
        case closed
        case overflow
    }

    struct Snapshot: Equatable, Sendable {
        let pendingBytes: Int
        let pendingEvents: Int
        let queuedEvents: Int
        let acceptingEvents: Bool
    }

    private struct Entry: Sendable {
        let event: Event
        let retainedBytes: Int
        let afterDelivery: (@Sendable () -> Void)?
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let handler: (Event) -> Void
    private let budget: RemoteDaemonEventDeliveryBudget
    private let limits: RemoteDaemonEventDeliveryLimits
    private var entries: [Entry?] = []
    private var head = 0
    private var reservedBytes = 0
    private var reservedEvents = 0
    private var drainScheduled = false
    private var acceptingEvents = true
    private var failureTerminal: (Event, (@Sendable () -> Void)?)?

    init(
        queue: DispatchQueue,
        handler: @escaping (Event) -> Void,
        budget: RemoteDaemonEventDeliveryBudget,
        limits: RemoteDaemonEventDeliveryLimits
    ) {
        self.queue = queue
        self.handler = handler
        self.budget = budget
        self.limits = limits
    }

    func enqueue(_ event: Event, retainedBytes: Int) -> EnqueueResult {
        append(event, retainedBytes: retainedBytes, afterDelivery: nil, closesInput: false)
    }

    func finish(
        _ event: Event,
        retainedBytes: Int,
        afterDelivery: (@Sendable () -> Void)?
    ) -> EnqueueResult {
        append(event, retainedBytes: retainedBytes, afterDelivery: afterDelivery, closesInput: true)
    }

    func fail(
        _ terminal: Event,
        afterDelivery: (@Sendable () -> Void)? = nil
    ) {
        let released: (bytes: Int, events: Int)
        let scheduleDrain: Bool
        lock.lock()
        acceptingEvents = false
        released = clearQueuedEntriesLocked()
        failureTerminal = (terminal, afterDelivery)
        scheduleDrain = !drainScheduled
        if scheduleDrain {
            drainScheduled = true
        }
        lock.unlock()
        if released.events > 0 {
            budget.release(bytes: released.bytes, events: released.events)
        }
        if scheduleDrain {
            scheduleDrainBlock()
        }
    }

    func cancel() {
        let released: (bytes: Int, events: Int)
        lock.lock()
        acceptingEvents = false
        failureTerminal = nil
        released = clearQueuedEntriesLocked()
        lock.unlock()
        if released.events > 0 {
            budget.release(bytes: released.bytes, events: released.events)
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            pendingBytes: reservedBytes,
            pendingEvents: reservedEvents,
            queuedEvents: max(0, entries.count - head) + (failureTerminal == nil ? 0 : 1),
            acceptingEvents: acceptingEvents
        )
    }

    private func append(
        _ event: Event,
        retainedBytes: Int,
        afterDelivery: (@Sendable () -> Void)?,
        closesInput: Bool
    ) -> EnqueueResult {
        guard retainedBytes >= 0 else { return .overflow }

        let scheduleDrain: Bool
        lock.lock()
        guard acceptingEvents else {
            lock.unlock()
            return .closed
        }
        guard reservedEvents < limits.maxPendingEvents,
              reservedBytes <= limits.maxPendingBytes,
              retainedBytes <= limits.maxPendingBytes - reservedBytes else {
            acceptingEvents = false
            lock.unlock()
            return .overflow
        }
        guard budget.reserve(bytes: retainedBytes) else {
            acceptingEvents = false
            lock.unlock()
            return .overflow
        }

        reservedEvents += 1
        reservedBytes += retainedBytes
        entries.append(
            Entry(
                event: event,
                retainedBytes: retainedBytes,
                afterDelivery: afterDelivery
            )
        )
        if closesInput {
            acceptingEvents = false
        }
        scheduleDrain = !drainScheduled
        if scheduleDrain {
            drainScheduled = true
        }
        lock.unlock()

        if scheduleDrain {
            scheduleDrainBlock()
        }
        return .enqueued
    }

    private func scheduleDrainBlock() {
        queue.async {
            self.drainBatch()
        }
    }

    private func drainBatch() {
        var delivered = 0
        while delivered < remoteDaemonEventDeliveryDrainBatchSize {
            let next: (entry: Entry?, failure: (Event, (@Sendable () -> Void)?)?)
            lock.lock()
            if head < entries.count {
                let entry = entries[head]
                entries[head] = nil
                head += 1
                next = (entry, nil)
            } else if let failureTerminal {
                self.failureTerminal = nil
                next = (nil, failureTerminal)
            } else {
                entries.removeAll(keepingCapacity: false)
                head = 0
                drainScheduled = false
                lock.unlock()
                return
            }
            lock.unlock()

            if let entry = next.entry {
                handler(entry.event)
                lock.lock()
                reservedBytes = max(0, reservedBytes - entry.retainedBytes)
                reservedEvents = max(0, reservedEvents - 1)
                lock.unlock()
                budget.release(bytes: entry.retainedBytes)
                entry.afterDelivery?()
            } else if let failure = next.failure {
                handler(failure.0)
                failure.1?()
            }
            delivered += 1
        }

        lock.lock()
        let hasMore = head < entries.count || failureTerminal != nil
        if !hasMore {
            entries.removeAll(keepingCapacity: false)
            head = 0
            drainScheduled = false
        }
        lock.unlock()
        if hasMore {
            scheduleDrainBlock()
        }
    }

    private func clearQueuedEntriesLocked() -> (bytes: Int, events: Int) {
        guard head < entries.count else {
            entries.removeAll(keepingCapacity: false)
            head = 0
            return (0, 0)
        }
        var bytes = 0
        var events = 0
        for index in head..<entries.count {
            guard let entry = entries[index] else { continue }
            bytes += entry.retainedBytes
            events += 1
            entries[index] = nil
        }
        reservedBytes = max(0, reservedBytes - bytes)
        reservedEvents = max(0, reservedEvents - events)
        entries.removeAll(keepingCapacity: false)
        head = 0
        return (bytes, events)
    }
}
