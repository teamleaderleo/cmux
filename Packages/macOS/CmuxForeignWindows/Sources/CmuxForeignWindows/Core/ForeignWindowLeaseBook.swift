import CoreGraphics
import Foundation

/// Pure leasing rules shared by every profile.
///
/// - A live panel *claims* a profile for as long as it is open. Claims keep the
///   profile's process alive; the process ends when the last claim is released.
/// - A host view *attaches* while it exists. Attaching never launches or kills
///   anything by itself; it only makes the host eligible to present.
/// - At most one host presents a profile's window. Candidates are visible hosts
///   whose panel still claims the profile. A focused candidate wins; otherwise
///   the candidate that most recently became visible or focused wins.
struct ForeignWindowLeaseBook {
    struct HostLease: Equatable {
        let panelID: UUID
        let profile: String
        var isVisible: Bool
        var isFocused: Bool
        var targetFrame: CGRect?
        var activation: UInt64
    }

    private(set) var panelProfiles: [UUID: String] = [:]
    private(set) var hosts: [UUID: HostLease] = [:]
    private var activationClock: UInt64 = 0

    var claimedProfiles: Set<String> { Set(panelProfiles.values) }

    func isClaimed(_ profile: String) -> Bool {
        panelProfiles.values.contains(profile)
    }

    func profile(forPanel panelID: UUID) -> String? {
        panelProfiles[panelID]
    }

    mutating func claim(profile: String, panelID: UUID) {
        panelProfiles[panelID] = profile
    }

    /// Releases a panel's claim. Returns the profile when that release left it
    /// with no live panel, meaning its process should end.
    @discardableResult
    mutating func release(panelID: UUID) -> String? {
        guard let profile = panelProfiles.removeValue(forKey: panelID) else {
            return nil
        }
        return isClaimed(profile) ? nil : profile
    }

    mutating func attach(hostID: UUID, panelID: UUID, profile: String) {
        if let existing = hosts[hostID],
           existing.panelID == panelID,
           existing.profile == profile {
            return
        }
        hosts[hostID] = HostLease(
            panelID: panelID,
            profile: profile,
            isVisible: false,
            isFocused: false,
            targetFrame: nil,
            activation: 0
        )
    }

    mutating func detach(hostID: UUID) {
        hosts.removeValue(forKey: hostID)
    }

    mutating func update(
        hostID: UUID,
        isVisible: Bool,
        isFocused: Bool,
        targetFrame: CGRect?
    ) {
        guard var lease = hosts[hostID] else { return }
        if (isVisible && !lease.isVisible) || (isFocused && !lease.isFocused) {
            activationClock += 1
            lease.activation = activationClock
        }
        lease.isVisible = isVisible
        lease.isFocused = isFocused
        lease.targetFrame = targetFrame
        hosts[hostID] = lease
    }

    func presenter(for profile: String) -> UUID? {
        let candidates = hosts.filter { _, lease in
            lease.profile == profile
                && lease.isVisible
                && panelProfiles[lease.panelID] == profile
        }
        let focused = candidates.filter { $0.value.isFocused }
        let pool = focused.isEmpty ? candidates : focused
        return pool.max { lhs, rhs in
            if lhs.value.activation != rhs.value.activation {
                return lhs.value.activation < rhs.value.activation
            }
            // Deterministic tie-break for hosts that never became visible.
            return lhs.key.uuidString < rhs.key.uuidString
        }?.key
    }
}
