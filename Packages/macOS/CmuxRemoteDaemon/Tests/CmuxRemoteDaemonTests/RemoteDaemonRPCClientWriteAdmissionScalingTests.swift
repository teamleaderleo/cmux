import Darwin
import Dispatch
import Foundation
import Testing
import CmuxCore
@testable import CmuxRemoteDaemon

private let fieldworkWriteScalingEnabled =
    ProcessInfo.processInfo.environment["CMUX_FIELDWORK_SCALING"] == "1"

@Suite(
    "RemoteDaemonRPCClient write admission scaling",
    .serialized,
    .enabled(if: fieldworkWriteScalingEnabled)
)
struct RemoteDaemonRPCClientWriteAdmissionScalingTests {
    @Test("responsive stdio transport settles 200 concurrent RPC callers")
    func responsiveTransportSettlesLargeCallerBurst() throws {
        let executable = try makeResponsiveTransport()
        defer { removeTransport(at: executable) }

        let client = makeClient()
        defer { client.stop() }
        client.transportExecutableOverride = executable
        try client.start()

        let callers = 200
        let failures = LockedCounter()
        let group = DispatchGroup()
        for _ in 0..<callers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    _ = try client.call(method: "hello", params: [:], timeout: 2)
                } catch {
                    failures.increment()
                }
            }
        }

        #expect(group.wait(timeout: .now() + 8) == .success)
        #expect(failures.value == 0)
    }

    @Test("physical stdio write stall does not strand queued RPC timeouts at scale")
    func physicalWriteStallMustBoundQueuedCallers() throws {
        let previousSIGPIPEHandler = Darwin.signal(SIGPIPE, SIG_IGN)
        defer { Darwin.signal(SIGPIPE, previousSIGPIPEHandler) }

        for callers in [1, 10, 50, 200] {
            try runPhysicalWriteStallCase(callers: callers)
        }
    }

    @Test("notification-only PTY writes do not strand bridge workers at scale")
    func notificationOnlyPTYWritesMustBoundPhysicalStall() throws {
        // One bridge write is capped at 256 KiB by RemotePTYBridgeInputFlow.
        // That is still comfortably larger than a Darwin pipe's writable
        // headroom after base64 + JSON framing, so it is a realistic payload
        // for proving notification write liveness without inventing a giant
        // out-of-contract message.
        let previousSIGPIPEHandler = Darwin.signal(SIGPIPE, SIG_IGN)
        defer { Darwin.signal(SIGPIPE, previousSIGPIPEHandler) }

        for callers in [1, 10, 50, 200] {
            try runNotificationWriteStallCase(callers: callers)
        }
    }

    private func runPhysicalWriteStallCase(callers: Int) throws {
        let executable = try makeStallingTransport(stallSeconds: 10)
        defer { removeTransport(at: executable) }

        let client = makeClient()
        defer { client.stop() }
        client.transportExecutableOverride = executable
        try client.start()

        let physicalWriteEntered = DispatchSemaphore(value: 0)
        let physicalWriteFinished = DispatchSemaphore(value: 0)
        let writeQueue = DispatchQueue(
            label: "com.cmux.tests.remote-daemon.physical-write-stall.\(callers)"
        )
        writeQueue.async {
            client.writeQueue.sync {
                physicalWriteEntered.signal()
                do {
                    try client.writePayload(Data(repeating: 0x78, count: 4 * 1024 * 1024))
                } catch {
                    // The transport retirement owns the expected write failure.
                }
                physicalWriteFinished.signal()
            }
        }

        #expect(physicalWriteEntered.wait(timeout: .now() + 1) == .success)
        #expect(
            physicalWriteFinished.wait(timeout: .now() + 0.15) == .timedOut,
            "fake transport did not produce a physical write stall"
        )

        let group = DispatchGroup()
        let completions = LockedCounter()
        for _ in 0..<callers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    _ = try client.call(method: "hello", params: [:], timeout: 0.05)
                } catch {
                    // Either a response timeout or transport failure is an
                    // acceptable bounded outcome. Remaining parked behind the
                    // physical writer is the failure this probe distinguishes.
                }
                completions.increment()
            }
        }

        let boundedDeadline: DispatchTime = .now() + 1.75
        let settledWithinBound = group.wait(timeout: boundedDeadline) == .success
        #expect(
            settledWithinBound,
            "\(callers) queued RPC callers remained behind one physical write past the write-liveness budget"
        )

        if !settledWithinBound {
            client.stop()
            #expect(
                group.wait(timeout: .now() + 1) == .success,
                "clean shutdown did not release \(callers) queued RPC callers"
            )
            #expect(
                physicalWriteFinished.wait(timeout: .now() + 1) == .success,
                "clean shutdown did not release the blocked physical write"
            )
        } else {
            #expect(physicalWriteFinished.wait(timeout: .now() + 1) == .success)
        }
        #expect(completions.value == callers)
    }

    private func runNotificationWriteStallCase(callers: Int) throws {
        let executable = try makeStallingTransport(stallSeconds: 10)
        defer { removeTransport(at: executable) }

        let client = makeClient()
        defer { client.stop() }
        client.transportExecutableOverride = executable
        try client.start()

        let payload = Data(repeating: 0x6e, count: 256 * 1024)
        let group = DispatchGroup()
        let completions = LockedCounter()
        let errors = LockedCounter()

        for index in 0..<callers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                client.writePTY(
                    sessionID: "fieldwork-session",
                    attachmentID: "fieldwork-attachment-\(index)",
                    attachmentToken: "fieldwork-token-\(index)",
                    data: payload
                ) { error in
                    if error != nil {
                        errors.increment()
                    }
                    completions.increment()
                    group.leave()
                }
            }
        }

        // A notification has no response phase, so write liveness itself must
        // own convergence. Leave the same scheduler margin as the RPC probe.
        let settledWithinBound = group.wait(timeout: .now() + 1.75) == .success
        #expect(
            settledWithinBound,
            "\(callers) PTY notification writers remained behind one physical write with no request/response owner to retire the transport"
        )

        if !settledWithinBound {
            // Negative control: direct transport teardown must release the
            // physical notification writer and every caller queued behind it.
            client.stop()
            #expect(
                group.wait(timeout: .now() + 1) == .success,
                "clean shutdown did not release \(callers) PTY notification writers"
            )
        }
        #expect(completions.value == callers)
        // A stalled transport should surface write/transport errors rather
        // than silently treating every queued notification as delivered.
        #expect(errors.value > 0)
    }

    private func makeClient() -> RemoteDaemonRPCClient {
        RemoteDaemonRPCClient(
            configuration: configuration(),
            remotePath: "/fake/cmuxd-remote",
            strings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "missing persistent PTY",
                missingRequiredFunctionality: "missing functionality"
            )
        ) { _ in }
    }

    private func configuration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "fake-host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: false,
            persistentDaemonSlot: nil
        )
    }

    private func makeResponsiveTransport() throws -> String {
        try makeTransport(scriptBody: """
        while IFS= read -r line; do
          id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          if [ -n "$id" ]; then
            printf '{"id":%s,"ok":true,"result":{"capabilities":["proxy.stream.push"],"transport":"responsive"}}\\n' "$id"
          fi
        done
        """)
    }

    private func makeStallingTransport(stallSeconds: Int) throws -> String {
        try makeTransport(scriptBody: """
        if IFS= read -r line; then
          id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          printf '{"id":%s,"ok":true,"result":{"capabilities":["proxy.stream.push"]}}\\n' "$id"
        else
          exit 1
        fi
        sleep \(stallSeconds)
        exit 0
        """)
    }

    private func makeTransport(scriptBody: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-remote-daemon-write-scaling-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("fake-ssh-write-scaling")
        let script = """
        #!/bin/sh
        set -eu
        \(scriptBody)
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        chmod(scriptURL.path, 0o755)
        return scriptURL.path
    }

    private func removeTransport(at path: String) {
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent()
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}
