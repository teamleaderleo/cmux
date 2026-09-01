import Darwin
import Dispatch
import Foundation
import Testing
import CmuxCore
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemonRPCClient write admission scaling", .serialized)
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
        // FileHandle writes to a pipe whose peer is terminated during the
        // cleanup control can raise SIGPIPE in a standalone Swift test host.
        // Ignore it for this serialized probe so the write reports its error
        // and every 1/10/50/200 case can finish. Restore the process handler
        // after the suite case returns.
        let previousSIGPIPEHandler = Darwin.signal(SIGPIPE, SIG_IGN)
        defer { Darwin.signal(SIGPIPE, previousSIGPIPEHandler) }

        // The response timeout passed to `call` is deliberately tiny. The
        // invariant under test is that callers cannot wait indefinitely before
        // reaching the timeout owner merely because another physical write is
        // wedged. Current main registers each call before `writeQueue.sync`
        // and starts `waitForCall` only after the write returns, so this test is
        // expected to be red until write admission itself has a deadline.
        for callers in [1, 10, 50, 200] {
            try runPhysicalWriteStallCase(callers: callers)
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
                    // Far above ordinary Darwin pipe capacity. The fake SSH
                    // helper remains alive but stops reading after `hello`, so
                    // this write should stay inside FileHandle.write until the
                    // explicit cleanup control stops the transport.
                    try client.writePayload(Data(repeating: 0x78, count: 4 * 1024 * 1024))
                } catch {
                    // The cleanup control owns the expected write failure.
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

        let boundedDeadline: DispatchTime = .now() + 0.75
        let settledWithinBound = group.wait(timeout: boundedDeadline) == .success
        #expect(
            settledWithinBound,
            "\(callers) queued RPC callers remained behind one physical write beyond their 50ms response timeout"
        )

        if !settledWithinBound {
            // Explicit clean-shutdown control. A direct stop must break the
            // physical writer and release every queued caller even though the
            // fake helper would otherwise remain alive for ten seconds.
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
        # Stay alive while deliberately refusing every subsequent stdin byte.
        # The finite sleep is only a test-process safety breaker.
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
