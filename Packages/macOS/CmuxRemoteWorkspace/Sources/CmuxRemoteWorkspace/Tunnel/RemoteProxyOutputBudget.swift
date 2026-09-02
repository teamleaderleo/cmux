import Foundation

struct RemoteProxySessionOutputLimits: Sendable {
    static let production = RemoteProxySessionOutputLimits(
        maxPendingBytes: 96 * 1024 * 1024,
        maxPendingSends: 65_536
    )

    let maxPendingBytes: Int
    let maxPendingSends: Int
}

final class RemoteProxyOutputBudget: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let pendingBytes: Int
        let pendingSends: Int
    }

    static let shared = RemoteProxyOutputBudget(
        maxPendingBytes: 256 * 1024 * 1024,
        maxPendingSends: 262_144
    )

    private let lock = NSLock()
    private let maxPendingBytes: Int
    private let maxPendingSends: Int
    private var pendingBytes = 0
    private var pendingSends = 0

    init(maxPendingBytes: Int, maxPendingSends: Int) {
        self.maxPendingBytes = max(0, maxPendingBytes)
        self.maxPendingSends = max(0, maxPendingSends)
    }

    func reserve(bytes: Int) -> RemoteProxyOutputReservation? {
        guard bytes >= 0 else { return nil }

        lock.lock()
        defer { lock.unlock() }

        guard pendingSends < maxPendingSends else { return nil }
        guard pendingBytes <= maxPendingBytes else { return nil }
        guard bytes <= maxPendingBytes - pendingBytes else { return nil }

        pendingSends += 1
        pendingBytes += bytes
        return RemoteProxyOutputReservation(budget: self, bytes: bytes)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(pendingBytes: pendingBytes, pendingSends: pendingSends)
    }

    fileprivate func release(bytes: Int) {
        lock.lock()
        pendingSends = max(0, pendingSends - 1)
        pendingBytes = max(0, pendingBytes - bytes)
        lock.unlock()
    }
}

final class RemoteProxyOutputReservation: @unchecked Sendable {
    private let lock = NSLock()
    private let bytes: Int
    private var budget: RemoteProxyOutputBudget?

    fileprivate init(budget: RemoteProxyOutputBudget, bytes: Int) {
        self.budget = budget
        self.bytes = bytes
    }

    func release() {
        let budget: RemoteProxyOutputBudget?
        lock.lock()
        budget = self.budget
        self.budget = nil
        lock.unlock()
        budget?.release(bytes: bytes)
    }

    deinit {
        release()
    }
}
