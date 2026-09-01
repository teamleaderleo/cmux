#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CLIENT = ROOT / "Packages/macOS/CmuxRemoteDaemon/Sources/CmuxRemoteDaemon/Client/RemoteDaemonRPCClient.swift"
EVENTS = ROOT / "Packages/macOS/CmuxRemoteDaemon/Sources/CmuxRemoteDaemon/Client/RemoteDaemonRPCClient+Events.swift"
BUDGET = ROOT / "Packages/macOS/CmuxRemoteDaemon/Sources/CmuxRemoteDaemon/Client/RemoteDaemonEventDeliveryBudget.swift"
TESTS = ROOT / "Packages/macOS/CmuxRemoteDaemon/Tests/CmuxRemoteDaemonTests/RemoteDaemonEventDeliveryBudgetTests.swift"


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one exact replacement target, found {count}")
    path.write_text(text.replace(old, new, 1))


def create_exact(path: Path, content: str) -> None:
    if path.exists():
        existing = path.read_text()
        if existing != content:
            raise SystemExit(f"{path}: already exists with different content")
        return
    path.write_text(content)


budget_source = '''import Foundation

/// Thread-safe admission accounting for decoded daemon push events that have
/// been accepted but whose subscriber callback has not returned yet.
final class RemoteDaemonEventDeliveryBudget: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let pendingBytes: Int
        let pendingEvents: Int
    }

    private let lock = NSLock()
    private let maxPendingBytes: Int
    private let maxPendingEvents: Int
    private var pendingBytes = 0
    private var pendingEvents = 0

    init(maxPendingBytes: Int, maxPendingEvents: Int) {
        self.maxPendingBytes = max(0, maxPendingBytes)
        self.maxPendingEvents = max(0, maxPendingEvents)
    }

    func reserve(bytes: Int) -> RemoteDaemonEventDeliveryReservation? {
        let requestedBytes = max(0, bytes)
        lock.lock()
        defer { lock.unlock() }

        guard pendingEvents < maxPendingEvents else { return nil }
        guard requestedBytes <= maxPendingBytes - pendingBytes else { return nil }
        pendingBytes += requestedBytes
        pendingEvents += 1
        return RemoteDaemonEventDeliveryReservation(budget: self, bytes: requestedBytes)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(pendingBytes: pendingBytes, pendingEvents: pendingEvents)
    }

    fileprivate func release(bytes: Int) {
        lock.lock()
        pendingBytes = max(0, pendingBytes - max(0, bytes))
        pendingEvents = max(0, pendingEvents - 1)
        lock.unlock()
    }
}

final class RemoteDaemonEventDeliveryReservation: @unchecked Sendable {
    private let lock = NSLock()
    private var budget: RemoteDaemonEventDeliveryBudget?
    private let bytes: Int

    fileprivate init(budget: RemoteDaemonEventDeliveryBudget, bytes: Int) {
        self.budget = budget
        self.bytes = bytes
    }

    func release() {
        let capturedBudget: RemoteDaemonEventDeliveryBudget?
        lock.lock()
        capturedBudget = budget
        budget = nil
        lock.unlock()
        capturedBudget?.release(bytes: bytes)
    }

    deinit {
        release()
    }
}

struct RemoteDaemonEventDeliveryReservations: Sendable {
    let subscription: RemoteDaemonEventDeliveryReservation
    let global: RemoteDaemonEventDeliveryReservation

    func release() {
        subscription.release()
        global.release()
    }
}
'''

create_exact(BUDGET, budget_source)

replace_once(
    CLIENT,
    '''    static let webSocketKeepaliveInterval: TimeInterval = 5.0
    static let ptyAttachCancellationWriteTimeout: TimeInterval = 1.0
''',
    '''    static let webSocketKeepaliveInterval: TimeInterval = 5.0
    static let ptyAttachCancellationWriteTimeout: TimeInterval = 1.0
    static let maxEventDeliveryBytesPerSubscription = 8 * 1024 * 1024
    static let maxEventDeliveryEventsPerSubscription = 4_096
    static let maxEventDeliveryBytesGlobal = 64 * 1024 * 1024
    static let maxEventDeliveryEventsGlobal = 16_384
''',
)

replace_once(
    CLIENT,
    '''    struct StreamSubscription: @unchecked Sendable {
        let queue: DispatchQueue
        let handler: (RemoteDaemonStreamEvent) -> Void
    }

    // See StreamSubscription for the @unchecked Sendable justification.
    struct PTYSubscription: @unchecked Sendable {
        let queue: DispatchQueue
        let handler: (RemoteDaemonPTYEvent) -> Void
    }
''',
    '''    struct StreamSubscription: @unchecked Sendable {
        let queue: DispatchQueue
        let handler: (RemoteDaemonStreamEvent) -> Void
        let deliveryBudget: RemoteDaemonEventDeliveryBudget

        init(
            queue: DispatchQueue,
            handler: @escaping (RemoteDaemonStreamEvent) -> Void,
            deliveryBudget: RemoteDaemonEventDeliveryBudget? = nil
        ) {
            self.queue = queue
            self.handler = handler
            self.deliveryBudget = deliveryBudget ?? RemoteDaemonEventDeliveryBudget(
                maxPendingBytes: RemoteDaemonRPCClient.maxEventDeliveryBytesPerSubscription,
                maxPendingEvents: RemoteDaemonRPCClient.maxEventDeliveryEventsPerSubscription
            )
        }
    }

    // See StreamSubscription for the @unchecked Sendable justification.
    struct PTYSubscription: @unchecked Sendable {
        let queue: DispatchQueue
        let handler: (RemoteDaemonPTYEvent) -> Void
        let deliveryBudget: RemoteDaemonEventDeliveryBudget

        init(
            queue: DispatchQueue,
            handler: @escaping (RemoteDaemonPTYEvent) -> Void,
            deliveryBudget: RemoteDaemonEventDeliveryBudget? = nil
        ) {
            self.queue = queue
            self.handler = handler
            self.deliveryBudget = deliveryBudget ?? RemoteDaemonEventDeliveryBudget(
                maxPendingBytes: RemoteDaemonRPCClient.maxEventDeliveryBytesPerSubscription,
                maxPendingEvents: RemoteDaemonRPCClient.maxEventDeliveryEventsPerSubscription
            )
        }
    }
''',
)

replace_once(
    CLIENT,
    '''    let cliRequestQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.cli.\\(UUID().uuidString)", qos: .utility, attributes: .concurrent)
    let pendingCalls = RemoteDaemonPendingCallRegistry()
''',
    '''    let cliRequestQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.cli.\\(UUID().uuidString)", qos: .utility, attributes: .concurrent)
    let pendingCalls = RemoteDaemonPendingCallRegistry()
    let eventDeliveryBudget = RemoteDaemonEventDeliveryBudget(
        maxPendingBytes: RemoteDaemonRPCClient.maxEventDeliveryBytesGlobal,
        maxPendingEvents: RemoteDaemonRPCClient.maxEventDeliveryEventsGlobal
    )
''',
)

replace_once(
    EVENTS,
    '''        let subscription: StreamSubscription?
        let event: RemoteDaemonStreamEvent?
        switch eventName {
        case "proxy.stream.data":
            subscription = streamSubscriptions[streamID]
            event = .data(Self.decodeBase64Data(payload["data_base64"]))

        case "proxy.stream.eof":
            subscription = streamSubscriptions.removeValue(forKey: streamID)
            event = .eof(Self.decodeBase64Data(payload["data_base64"]))

        case "proxy.stream.error":
            subscription = streamSubscriptions.removeValue(forKey: streamID)
            let detail = ((payload["error"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "stream error"
            event = .error(detail)

        default:
            return
        }

        guard let subscription, let event else { return }
        subscription.queue.async {
            subscription.handler(event)
        }
''',
    '''        switch eventName {
        case "proxy.stream.data":
            guard let subscription = streamSubscriptions[streamID] else { return }
            let data = Self.decodeBase64Data(payload["data_base64"])
            enqueueStreamDeliveryLocked(
                streamID: streamID,
                subscription: subscription,
                event: .data(data),
                bytes: data.count
            )

        case "proxy.stream.eof":
            guard let subscription = streamSubscriptions.removeValue(forKey: streamID) else { return }
            let data = Self.decodeBase64Data(payload["data_base64"])
            enqueueStreamDeliveryLocked(
                streamID: streamID,
                subscription: subscription,
                event: .eof(data),
                bytes: data.count
            )

        case "proxy.stream.error":
            guard let subscription = streamSubscriptions.removeValue(forKey: streamID) else { return }
            let detail = ((payload["error"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "stream error"
            subscription.queue.async {
                subscription.handler(.error(detail))
            }

        default:
            return
        }
''',
)

replace_once(
    EVENTS,
    '''        let subscription: PTYSubscription?
        let event: RemoteDaemonPTYEvent?
        switch eventName {
        case "pty.ready":
            subscription = ptySubscriptions[key] ?? ptySubscriptions[legacyKey]
            event = .ready

        case "pty.data":
            subscription = ptySubscriptions[key] ?? ptySubscriptions[legacyKey]
            event = .data(Self.decodeBase64Data(payload["data_base64"]))

        case "pty.input_ack":
            subscription = ptySubscriptions[key] ?? ptySubscriptions[legacyKey]
            event = .inputAck(seq: rpcEventUInt64Value(payload["seq"]))

        case "pty.exit":
            subscription = ptySubscriptions.removeValue(forKey: key)
                ?? ptySubscriptions.removeValue(forKey: legacyKey)
            event = .exit

        case "pty.error":
            subscription = ptySubscriptions.removeValue(forKey: key)
                ?? ptySubscriptions.removeValue(forKey: legacyKey)
            let detail = ((payload["error"] as? String) ?? (payload["message"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            event = .error(detail?.isEmpty == false ? detail! : "PTY error")

        default:
            return true
        }

        guard let subscription, let event else { return true }
        subscription.queue.async {
            subscription.handler(event)
        }
        return true
''',
    '''        switch eventName {
        case "pty.ready":
            guard let matched = matchedPTYSubscriptionLocked(key: key, legacyKey: legacyKey) else { return true }
            enqueuePTYDeliveryLocked(
                subscriptionKey: matched.key,
                subscription: matched.subscription,
                event: .ready,
                bytes: 0
            )

        case "pty.data":
            guard let matched = matchedPTYSubscriptionLocked(key: key, legacyKey: legacyKey) else { return true }
            let data = Self.decodeBase64Data(payload["data_base64"])
            enqueuePTYDeliveryLocked(
                subscriptionKey: matched.key,
                subscription: matched.subscription,
                event: .data(data),
                bytes: data.count
            )

        case "pty.input_ack":
            guard let matched = matchedPTYSubscriptionLocked(key: key, legacyKey: legacyKey) else { return true }
            enqueuePTYDeliveryLocked(
                subscriptionKey: matched.key,
                subscription: matched.subscription,
                event: .inputAck(seq: rpcEventUInt64Value(payload["seq"])),
                bytes: 0
            )

        case "pty.exit":
            guard let matched = removePTYSubscriptionLocked(key: key, legacyKey: legacyKey) else { return true }
            matched.subscription.queue.async {
                matched.subscription.handler(.exit)
            }

        case "pty.error":
            guard let matched = removePTYSubscriptionLocked(key: key, legacyKey: legacyKey) else { return true }
            let detail = ((payload["error"] as? String) ?? (payload["message"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedDetail = detail?.isEmpty == false ? detail! : "PTY error"
            matched.subscription.queue.async {
                matched.subscription.handler(.error(resolvedDetail))
            }

        default:
            return true
        }
        return true
''',
)

replace_once(
    EVENTS,
    '''    func sendCLIResponse(requestID: String, data: Data?, error: String?) {
''',
    '''    private func matchedPTYSubscriptionLocked(
        key: String,
        legacyKey: String
    ) -> (key: String, subscription: PTYSubscription)? {
        if let subscription = ptySubscriptions[key] {
            return (key, subscription)
        }
        if let subscription = ptySubscriptions[legacyKey] {
            return (legacyKey, subscription)
        }
        return nil
    }

    private func removePTYSubscriptionLocked(
        key: String,
        legacyKey: String
    ) -> (key: String, subscription: PTYSubscription)? {
        if let subscription = ptySubscriptions.removeValue(forKey: key) {
            return (key, subscription)
        }
        if let subscription = ptySubscriptions.removeValue(forKey: legacyKey) {
            return (legacyKey, subscription)
        }
        return nil
    }

    private func reserveEventDeliveryLocked(
        subscriptionBudget: RemoteDaemonEventDeliveryBudget,
        bytes: Int
    ) -> RemoteDaemonEventDeliveryReservations? {
        guard let subscriptionReservation = subscriptionBudget.reserve(bytes: bytes) else {
            return nil
        }
        guard let globalReservation = eventDeliveryBudget.reserve(bytes: bytes) else {
            subscriptionReservation.release()
            return nil
        }
        return RemoteDaemonEventDeliveryReservations(
            subscription: subscriptionReservation,
            global: globalReservation
        )
    }

    private func enqueueStreamDeliveryLocked(
        streamID: String,
        subscription: StreamSubscription,
        event: RemoteDaemonStreamEvent,
        bytes: Int
    ) {
        guard let reservations = reserveEventDeliveryLocked(
            subscriptionBudget: subscription.deliveryBudget,
            bytes: bytes
        ) else {
            if let current = streamSubscriptions[streamID],
               current.deliveryBudget === subscription.deliveryBudget {
                streamSubscriptions.removeValue(forKey: streamID)
            }
            subscription.queue.async {
                subscription.handler(.error("proxy stream delivery exceeded local queue capacity"))
            }
            return
        }

        subscription.queue.async {
            defer { reservations.release() }
            subscription.handler(event)
        }
    }

    private func enqueuePTYDeliveryLocked(
        subscriptionKey: String,
        subscription: PTYSubscription,
        event: RemoteDaemonPTYEvent,
        bytes: Int
    ) {
        guard let reservations = reserveEventDeliveryLocked(
            subscriptionBudget: subscription.deliveryBudget,
            bytes: bytes
        ) else {
            if let current = ptySubscriptions[subscriptionKey],
               current.deliveryBudget === subscription.deliveryBudget {
                ptySubscriptions.removeValue(forKey: subscriptionKey)
            }
            subscription.queue.async {
                subscription.handler(.error("remote PTY delivery exceeded local queue capacity"))
            }
            return
        }

        subscription.queue.async {
            defer { reservations.release() }
            subscription.handler(event)
        }
    }

    func sendCLIResponse(requestID: String, data: Data?, error: String?) {
''',
)

tests_source = '''import Dispatch
import Foundation
import Testing
import CmuxCore
@testable import CmuxRemoteDaemon

@Suite("Remote daemon event delivery budget")
struct RemoteDaemonEventDeliveryBudgetTests {
    @Test("byte and event ceilings release idempotently")
    func byteAndEventCeilingsReleaseIdempotently() throws {
        let budget = RemoteDaemonEventDeliveryBudget(maxPendingBytes: 8, maxPendingEvents: 2)
        let first = try #require(budget.reserve(bytes: 5))
        let second = try #require(budget.reserve(bytes: 3))
        #expect(budget.snapshot() == .init(pendingBytes: 8, pendingEvents: 2))
        #expect(budget.reserve(bytes: 0) == nil)
        #expect(budget.reserve(bytes: 1) == nil)

        first.release()
        first.release()
        #expect(budget.snapshot() == .init(pendingBytes: 3, pendingEvents: 1))
        let replacement = try #require(budget.reserve(bytes: 5))
        #expect(budget.snapshot() == .init(pendingBytes: 8, pendingEvents: 2))

        second.release()
        replacement.release()
        #expect(budget.snapshot() == .init(pendingBytes: 0, pendingEvents: 0))
    }

    @Test("stream overflow retires only the overflowing subscription after admitted events")
    func streamOverflowRetiresSubscription() throws {
        let client = makeDeliveryBudgetClient()
        let queue = DispatchQueue(label: "com.cmux.tests.stream-delivery-budget")
        let gate = DispatchSemaphore(value: 0)
        let recorder = StreamEventRecorder()
        queue.async { gate.wait() }
        let localBudget = RemoteDaemonEventDeliveryBudget(maxPendingBytes: 64 * 1024, maxPendingEvents: 2)
        client.stateQueue.sync {
            client.streamSubscriptions["stream"] = .init(
                queue: queue,
                handler: { recorder.record($0) },
                deliveryBudget: localBudget
            )
            client.streamSubscriptions["other"] = .init(queue: queue, handler: { _ in })
        }
        let encoded = Data(repeating: 0x61, count: 32 * 1024).base64EncodedString()
        let payload: [String: Any] = [
            "event": "proxy.stream.data",
            "stream_id": "stream",
            "data_base64": encoded,
        ]

        client.stateQueue.sync {
            client.consumeEventPayload(payload)
            client.consumeEventPayload(payload)
            client.consumeEventPayload(payload)
            client.consumeEventPayload(payload)
        }
        #expect(client.stateQueue.sync { !client.streamSubscriptions.keys.contains("stream") })
        #expect(client.stateQueue.sync { client.streamSubscriptions.keys.contains("other") })
        #expect(localBudget.snapshot() == .init(pendingBytes: 64 * 1024, pendingEvents: 2))

        gate.signal()
        #expect(waitForDeliveryBudget(timeout: 3) { recorder.snapshot().count == 3 })
        let events = recorder.snapshot()
        #expect(events.count == 3)
        #expect(events.filter { $0 == "data" }.count == 2)
        #expect(events.last == "error")
        #expect(waitForDeliveryBudget(timeout: 3) {
            localBudget.snapshot() == .init(pendingBytes: 0, pendingEvents: 0)
        })
    }

    @Test("PTY overflow retires only the overflowing attachment after admitted events")
    func ptyOverflowRetiresSubscription() throws {
        let client = makeDeliveryBudgetClient()
        let queue = DispatchQueue(label: "com.cmux.tests.pty-delivery-budget")
        let gate = DispatchSemaphore(value: 0)
        let recorder = PTYEventRecorder()
        queue.async { gate.wait() }
        let localBudget = RemoteDaemonEventDeliveryBudget(maxPendingBytes: 64 * 1024, maxPendingEvents: 2)
        let sessionID = "session"
        let attachmentID = "attachment"
        let token = "token"
        let key = RemoteDaemonRPCClient.ptySubscriptionKey(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: token
        )
        let otherKey = RemoteDaemonRPCClient.ptySubscriptionKey(
            sessionID: sessionID,
            attachmentID: "other",
            attachmentToken: token
        )
        client.stateQueue.sync {
            client.ptySubscriptions[key] = .init(
                queue: queue,
                handler: { recorder.record($0) },
                deliveryBudget: localBudget
            )
            client.ptySubscriptions[otherKey] = .init(queue: queue, handler: { _ in })
        }
        let encoded = Data(repeating: 0x62, count: 32 * 1024).base64EncodedString()
        let payload: [String: Any] = [
            "event": "pty.data",
            "session_id": sessionID,
            "attachment_id": attachmentID,
            "attachment_token": token,
            "data_base64": encoded,
        ]

        client.stateQueue.sync {
            _ = client.consumePTYEventPayload(payload)
            _ = client.consumePTYEventPayload(payload)
            _ = client.consumePTYEventPayload(payload)
            _ = client.consumePTYEventPayload(payload)
        }
        #expect(client.stateQueue.sync { !client.ptySubscriptions.keys.contains(key) })
        #expect(client.stateQueue.sync { client.ptySubscriptions.keys.contains(otherKey) })
        #expect(localBudget.snapshot() == .init(pendingBytes: 64 * 1024, pendingEvents: 2))

        gate.signal()
        #expect(waitForDeliveryBudget(timeout: 3) { recorder.snapshot().count == 3 })
        let events = recorder.snapshot()
        #expect(events.count == 3)
        #expect(events.filter { $0 == "data" }.count == 2)
        #expect(events.last == "error")
        #expect(waitForDeliveryBudget(timeout: 3) {
            localBudget.snapshot() == .init(pendingBytes: 0, pendingEvents: 0)
        })
    }
}

private final class StreamEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: RemoteDaemonStreamEvent) {
        let label: String
        switch event {
        case .data(_): label = "data"
        case .eof(_): label = "eof"
        case .error(_): label = "error"
        }
        lock.lock()
        events.append(label)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class PTYEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: RemoteDaemonPTYEvent) {
        let label: String
        switch event {
        case .data(_): label = "data"
        case .ready: label = "ready"
        case .inputAck(_): label = "inputAck"
        case .exit: label = "exit"
        case .error(_): label = "error"
        }
        lock.lock()
        events.append(label)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private func makeDeliveryBudgetClient() -> RemoteDaemonRPCClient {
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

private func waitForDeliveryBudget(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
}
'''

create_exact(TESTS, tests_source)

print("staged bounded RemoteDaemonRPCClient event delivery candidate")
