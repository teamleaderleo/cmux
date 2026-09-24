import AppKit
public import Foundation

/// Owns one foreign-window session per profile key.
///
/// Sessions are created lazily when a claimed profile first has a visible
/// host, shared by every pane showing that profile, and survive host view
/// teardown. A session is invalidated (its process terminated) only when the
/// last panel claiming its profile closes, or when the app terminates.
///
/// A panel calls ``claim(profile:panelID:)`` when it opens and
/// ``releasePanel(_:)`` when it really closes. Host views attach and detach
/// themselves; see ``ForeignWindowHostView``.
///
/// ```swift
/// let registry = ForeignWindowProfileRegistry { profile in
///     FakeSession(profile: profile)
/// }
/// registry.claim(profile: "work", panelID: panel.id)
/// ```
@MainActor
public final class ForeignWindowProfileRegistry {
    /// Builds the session for a profile the first time it needs one.
    public typealias SessionFactory = @MainActor (String) -> any ForeignWindowProfileSession

    private struct WeakHost {
        weak var host: (any ForeignWindowProfileHost)?
    }

    private let makeSession: SessionFactory
    private let logger: ForeignWindowLogger
    private var book = ForeignWindowLeaseBook()
    private var sessions: [String: any ForeignWindowProfileSession] = [:]
    private var hostRefs: [UUID: WeakHost] = [:]
    private var presenters: [String: UUID] = [:]
    private var terminationObserver: (any NSObjectProtocol)?
    private var isTerminated = false

    /// Creates a registry.
    ///
    /// - Parameter observesApplicationTermination: Terminates every session on
    ///   `NSApplication.willTerminateNotification`. Tests pass `false`.
    /// - Parameter logger: Receives session lifecycle diagnostics.
    /// - Parameter makeSession: Builds the session for a profile.
    public init(
        observesApplicationTermination: Bool = true,
        logger: ForeignWindowLogger = .disabled,
        makeSession: @escaping SessionFactory
    ) {
        self.makeSession = makeSession
        self.logger = logger
        if observesApplicationTermination {
            // The registry is process-lifetime; the token is intentionally kept.
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.terminateAll()
                }
            }
        }
    }

    // MARK: Read API

    /// Profiles with at least one open panel.
    public var claimedProfiles: Set<String> { book.claimedProfiles }

    /// Profiles whose external process is currently running.
    public var runningProfiles: Set<String> {
        Set(sessions.compactMap { $0.value.isRunning ? $0.key : nil })
    }

    /// Profiles that have a session object (running or launching).
    public var sessionProfiles: Set<String> { Set(sessions.keys) }

    func isPresenting(hostID: UUID) -> Bool {
        guard let profile = book.hosts[hostID]?.profile else { return false }
        return presenters[profile] == hostID
    }

    // MARK: Panel claims

    /// Records that `panelID` uses `profile`, keeping its process alive.
    ///
    /// Re-claiming a panel with a different profile releases the previous one.
    ///
    /// - Parameter profile: The profile key.
    /// - Parameter panelID: The claiming panel.
    public func claim(profile: String, panelID: UUID) {
        let previous = book.profile(forPanel: panelID)
        book.claim(profile: profile, panelID: panelID)
        if let previous, previous != profile, !book.isClaimed(previous) {
            endSession(for: previous)
        }
        reconcile(profile: profile, raiseWindow: false)
    }

    /// Releases a panel that was really closed (not moved or re-rendered).
    ///
    /// Ends the profile's process when no other panel claims it.
    ///
    /// - Parameter panelID: The closing panel.
    public func releasePanel(_ panelID: UUID) {
        guard let profile = book.profile(forPanel: panelID) else { return }
        if book.release(panelID: panelID) != nil {
            endSession(for: profile)
        } else {
            reconcile(profile: profile, raiseWindow: false)
        }
    }

    // MARK: Host leases

    func attach(
        host: any ForeignWindowProfileHost,
        hostID: UUID,
        panelID: UUID,
        profile: String
    ) {
        if let existing = book.hosts[hostID], existing.profile != profile {
            detach(hostID: hostID)
        }
        hostRefs[hostID] = WeakHost(host: host)
        book.attach(hostID: hostID, panelID: panelID, profile: profile)
    }

    /// View teardown. Never terminates the process.
    func detach(hostID: UUID) {
        guard let profile = book.hosts[hostID]?.profile else {
            hostRefs.removeValue(forKey: hostID)
            return
        }
        book.detach(hostID: hostID)
        hostRefs.removeValue(forKey: hostID)
        if presenters[profile] == hostID {
            presenters.removeValue(forKey: profile)
        }
        reconcile(profile: profile, raiseWindow: false)
    }

    func updateHost(
        hostID: UUID,
        isVisible: Bool,
        isFocused: Bool,
        targetFrame: CGRect?,
        raiseWindow: Bool
    ) {
        guard let profile = book.hosts[hostID]?.profile else { return }
        book.update(
            hostID: hostID,
            isVisible: isVisible,
            isFocused: isFocused,
            targetFrame: targetFrame
        )
        reconcile(
            profile: profile,
            raiseWindow: raiseWindow,
            requestingHostID: hostID
        )
    }

    /// Terminates every session and blocks new ones. Used on app termination.
    public func terminateAll() {
        isTerminated = true
        for profile in Array(sessions.keys) {
            endSession(for: profile)
        }
    }

    // MARK: Private

    private func reconcile(
        profile: String,
        raiseWindow: Bool,
        requestingHostID: UUID? = nil
    ) {
        let previous = presenters[profile]
        let next = book.presenter(for: profile)
        let presenterChanged = previous != next
        if presenterChanged {
            presenters[profile] = next
            if let previous {
                hostRefs[previous]?.host?
                    .foreignWindowProfileHostDidChangePresenting(false)
            }
            if let next {
                hostRefs[next]?.host?
                    .foreignWindowProfileHostDidChangePresenting(true)
            }
        }

        guard let next, let lease = book.hosts[next] else {
            sessions[profile]?.updatePresentation(
                targetFrame: nil,
                isVisible: false,
                isFocused: false,
                raiseWindow: false
            )
            return
        }
        // A non-presenting host's own changes do not move the window.
        if !presenterChanged,
           let requestingHostID,
           requestingHostID != next {
            return
        }
        guard book.isClaimed(profile), !isTerminated else { return }
        let session = sessionForProfile(profile)
        session.updatePresentation(
            targetFrame: lease.targetFrame,
            isVisible: lease.isVisible,
            isFocused: lease.isFocused,
            raiseWindow: raiseWindow || presenterChanged
        )
    }

    private func sessionForProfile(_ profile: String) -> any ForeignWindowProfileSession {
        if let existing = sessions[profile] { return existing }
        let session = makeSession(profile)
        sessions[profile] = session
        logger("foreignWindow.registry.sessionCreated profile=\(profile)")
        return session
    }

    private func endSession(for profile: String) {
        if let presenter = presenters.removeValue(forKey: profile) {
            hostRefs[presenter]?.host?
                .foreignWindowProfileHostDidChangePresenting(false)
        }
        guard let session = sessions.removeValue(forKey: profile) else { return }
        logger("foreignWindow.registry.sessionEnded profile=\(profile)")
        session.invalidate()
    }
}
