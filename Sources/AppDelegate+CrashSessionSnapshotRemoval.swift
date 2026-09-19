import Foundation

extension AppDelegate {
    func syncManualRestoreSnapshotCachePruningCrashDiagnostics() {
        guard let primaryURL = sessionSnapshotStore.defaultSnapshotFileURL(),
              let backupURL = sessionSnapshotStore.manualRestoreSnapshotFileURL() else {
            return
        }
        switch sessionSnapshotStore.loadOutcome(fileURL: primaryURL) {
        case .loaded(let snapshot):
            Self.clearCrashOnlyPrimarySnapshotRemovalMarker()
            guard let prunedSnapshot = SessionPersistencePolicy
                .pruningCmuxCrashDiagnosticWindows(from: snapshot)
                .snapshot else {
                return
            }
            _ = sessionSnapshotStore.save(prunedSnapshot, fileURL: backupURL)
        case .missing:
            if !Self.hasCrashOnlyPrimarySnapshotRemovalMarker() {
                sessionSnapshotStore.removeSnapshot(fileURL: backupURL)
            }
        case .unusable:
            Self.clearCrashOnlyPrimarySnapshotRemovalMarker()
        }
    }

    nonisolated static func markCrashOnlyPrimarySnapshotRemoval(
        defaults: UserDefaults = .standard
    ) {
        SessionSnapshotPersistenceWriter.markCrashOnlyPrimarySnapshotRemoval(defaults: defaults)
    }

    nonisolated static func hasCrashOnlyPrimarySnapshotRemovalMarker(
        defaults: UserDefaults = .standard
    ) -> Bool {
        SessionSnapshotPersistenceWriter.hasCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults)
    }

    nonisolated static func clearCrashOnlyPrimarySnapshotRemovalMarker(
        defaults: UserDefaults = .standard
    ) {
        SessionSnapshotPersistenceWriter.clearCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults)
    }
}
