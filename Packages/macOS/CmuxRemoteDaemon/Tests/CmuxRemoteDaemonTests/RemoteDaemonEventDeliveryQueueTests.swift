import Darwin
import Dispatch
import Foundation
import Testing
import CmuxCore
@testable import CmuxRemoteDaemon

@Suite("Remote daemon bounded event delivery", .serialized)
struct RemoteDaemonEventDeliveryQueueTests {
    @Test("budget enforces byte and event ceilings")
    func budgetEnforcesBothCeilings() {
        let budget = RemoteDaemonEventDeliveryBudget(maxPendingBytes: 10, maxPendingEvents: 2)
        #expect(budget.reserve(bytes: 4))
        #expect(budget.reserve(bytes: 6))
        #expect(!budget.reserve(bytes: 0))
        #expect(!budget.reserve(bytes: 1))
        #expect(budget.snapshot() == .init(pendingBytes: 10, pendingEvents: 2))
        budget.release(bytes: 4)
        #expect(budget.snapshot() == .init(pendingBytes: 6, pendingEvents: 1))
        budget.release(bytes: 6)
        #expect(budget.snapshot() == .init(pendingBytes: 0, pendingEvents: 0))
    }

    @Test("healthy delivery preserves FIFO order through one terminal event")
    func healthyDeliveryPreservesOrder() {
        let queue = DispatchQueue(label: "com.cmux.test.event-delivery-order")
        let received = LockedStrings()
        let terminal = DispatchSemaphore(value: 0)
        let budget = RemoteDaemonEventDeliveryBudget(maxPendingBytes: 64, maxPendingEvents: 16)
        let delivery = RemoteDaemonEventDeliveryQueue<String>(
            queue: queue,
            handler: { value in received.append(value) },
            budget: budget,
            limits: .init(maxPendingBytes: 64, maxPendingEvents: 16)
        )

        #expect(matchesEnqueued(delivery.enqueue("a", retainedBytes: 1)))
        #expect(matchesEnqueued(delivery.enqueue("b", retainedBytes: 1)))
        #expect(matchesEnqueued(delivery.finish("end", retainedBytes: 0, afterDelivery: { terminal.signal() })))
        #expect(terminal.wait(timeout: .now() + 2) == .success)
        #expect(received.values == ["a", "b", "end"])
        #expect(budget.snapshot() == .init(pendingBytes: 0, pendingEvents: 0))
    }

    @Test("overflow releases queued payload before the target queue resumes")
    func overflowReleasesQueuedPayloadImmediately() {
        let queue = DispatchQueue(label: "com.cmux.test.event-delivery-overflow")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let received = LockedStrings()
        let budget = RemoteDaemonEventDeliveryBudget(maxPendingBytes: 64, maxPendingEvents: 16)
        let delivery = RemoteDaemonEventDeliveryQueue<String>(
            queue: queue,
            handler: { value in received.append(value) },
            budget: budget,
            limits: .init(maxPendingBytes: 8, maxPendingEvents: 2)
        )

        #expect(matchesEnqueued(delivery.enqueue("a", retainedBytes: 4)))
        #expect(matchesEnqueued(delivery.enqueue("b", retainedBytes: 4)))
        #expect(matchesOverflow(delivery.enqueue("c", retainedBytes: 1)))
        delivery.fail("overflow")
        #expect(delivery.snapshot().pendingBytes == 0)
        #expect(delivery.snapshot().pendingEvents == 0)
        #expect(budget.snapshot() == .init(pendingBytes: 0, pendingEvents: 0))

        gate.signal()
        #expect(waitUntilEventDelivery(timeout: 2) { received.values == ["overflow"] })
    }

    @Test("cancel releases a blocked queue without invoking stale handlers")
    func cancelReleasesBlockedQueue() {
        let queue = DispatchQueue(label: "com.cmux.test.event-delivery-cancel")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let received = LockedStrings()
        let budget = RemoteDaemonEventDeliveryBudget(maxPendingBytes: 64, maxPendingEvents: 16)
        let delivery = RemoteDaemonEventDeliveryQueue<String>(
            queue: queue,
            handler: { value in received.append(value) },
            budget: budget,
            limits: .init(maxPendingBytes: 64, maxPendingEvents: 16)
        )
        #expect(matchesEnqueued(delivery.enqueue("stale", retainedBytes: 32)))
        delivery.cancel()
        #expect(budget.snapshot() == .init(pendingBytes: 0, pendingEvents: 0))
        gate.signal()
        Thread.sleep(forTimeInterval: 0.05)
        #expect(received.values.isEmpty)
    }

    @Test("overflow terminal handler may unregister the stream without queue inversion")
    func overflowHandlerMayUnregisterWithoutDeadlock() {
        let client = makeDeliveryClient()
        let deliveryQueue = DispatchQueue(label: "com.cmux.test.event-delivery-unregister")
        let deliveryGate = DispatchSemaphore(value: 0)
        deliveryQueue.async { deliveryGate.wait() }
        let budget = RemoteDaemonEventDeliveryBudget(maxPendingBytes: 8, maxPendingEvents: 8)
        let terminal = DispatchSemaphore(value: 0)
        let streamID = "bounded-stream"
        let subscription = RemoteDaemonRPCClient.StreamSubscription(
            queue: deliveryQueue,
            handler: { event in
                if case .error = event {
                    client.unregisterStream(streamID: streamID)
                    terminal.signal()
                }
            },
            budget: budget,
            limits: .init(maxPendingBytes: 4, maxPendingEvents: 2)
        )
        client.stateQueue.sync {
            client.streamSubscriptions[streamID] = subscription
        }
        let payload = Data(repeating: 0x78, count: 4).base64EncodedString()
        client.stateQueue.sync {
            client.consumeEventPayload([
                "event": "proxy.stream.data",
                "stream_id": streamID,
                "data_base64": payload,
            ])
            client.consumeEventPayload([
                "event": "proxy.stream.data",
                "stream_id": streamID,
                "data_base64": payload,
            ])
        }
        #expect(client.stateQueue.sync { client.streamSubscriptions[streamID] == nil })
        deliveryGate.signal()
        #expect(terminal.wait(timeout: .now() + 2) == .success)
        #expect(budget.snapshot() == .init(pendingBytes: 0, pendingEvents: 0))
    }

    @Test("PTY overflow retires the attachment before terminal delivery")
    func ptyOverflowRetiresBeforeTerminalDelivery() {
        let client = makeDeliveryClient()
        let deliveryQueue = DispatchQueue(label: "com.cmux.test.pty-event-delivery-retirement")
        let deliveryGate = DispatchSemaphore(value: 0)
        deliveryQueue.async { deliveryGate.wait() }
        let budget = RemoteDaemonEventDeliveryBudget(maxPendingBytes: 8, maxPendingEvents: 8)
        let terminal = DispatchSemaphore(value: 0)
        let sessionID = "bounded-session"
        let attachmentID = "bounded-attachment"
        let token = "bounded-token"
        let key = RemoteDaemonRPCClient.ptySubscriptionKey(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: token
        )
        let subscription = RemoteDaemonRPCClient.PTYSubscription(
            queue: deliveryQueue,
            handler: { event in
                if case .error = event {
                    client.unregisterPTY(
                        sessionID: sessionID,
                        attachmentID: attachmentID,
                        attachmentToken: token
                    )
                    terminal.signal()
                }
            },
            budget: budget,
            limits: .init(maxPendingBytes: 4, maxPendingEvents: 2)
        )
        client.stateQueue.sync {
            client.ptySubscriptions[key] = subscription
        }
        let payload = Data(repeating: 0x78, count: 4).base64EncodedString()
        client.stateQueue.sync {
            _ = client.consumePTYEventPayload([
                "event": "pty.data",
                "session_id": sessionID,
                "attachment_id": attachmentID,
                "attachment_token": token,
                "data_base64": payload,
            ])
            _ = client.consumePTYEventPayload([
                "event": "pty.data",
                "session_id": sessionID,
                "attachment_id": attachmentID,
                "attachment_token": token,
                "data_base64": payload,
            ])
        }
        #expect(client.stateQueue.sync { client.ptySubscriptions[key] == nil })
        #expect(budget.snapshot() == .init(pendingBytes: 0, pendingEvents: 0))
        deliveryGate.signal()
        #expect(terminal.wait(timeout: .now() + 2) == .success)
        #expect(budget.snapshot() == .init(pendingBytes: 0, pendingEvents: 0))
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}

private final class LockedIntValue: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}

private func matchesEnqueued<Event: Sendable>(_ result: RemoteDaemonEventDeliveryQueue<Event>.EnqueueResult) -> Bool {
    if case .enqueued = result { return true }
    return false
}

private func matchesOverflow<Event: Sendable>(_ result: RemoteDaemonEventDeliveryQueue<Event>.EnqueueResult) -> Bool {
    if case .overflow = result { return true }
    return false
}

private func waitUntilEventDelivery(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
}

private func makeDeliveryClient() -> RemoteDaemonRPCClient {
    RemoteDaemonRPCClient(
        configuration: WorkspaceRemoteConfiguration(
            destination: "user@example-host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        ),
        remotePath: "/usr/local/bin/cmuxd-remote",
        strings: RemoteDaemonStrings(
            missingPersistentPTYCapability: "missing persistent PTY",
            missingRequiredFunctionality: "missing required functionality"
        ),
        onUnexpectedTermination: { _ in }
    )
}

private func eventDeliveryRSSKiB() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size / 1024) : -1
}

private func printEventDeliveryJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    print("FIELDWORK_BOUNDED_DELIVERY \(String(decoding: data, as: UTF8.self))")
}
