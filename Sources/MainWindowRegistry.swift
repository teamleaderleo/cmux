import AppKit

/// Owns the identity index that maps terminal windows to their main-window contexts.
@MainActor
final class MainWindowRegistry {
    typealias Context = AppDelegate.MainWindowContext

    private(set) var contexts: [ObjectIdentifier: Context] = [:]

    /// Returns the context currently indexed for `window`.
    func context(for window: NSWindow) -> Context? {
        contexts[ObjectIdentifier(window)]
    }

    /// Returns the context currently indexed under `key`.
    func context(for key: ObjectIdentifier) -> Context? {
        contexts[key]
    }

    /// Inserts `context` under the window's identity key.
    func insert(_ context: Context, for window: NSWindow) {
        contexts[ObjectIdentifier(window)] = context
    }

    /// Removes every key currently referring to `context`.
    @discardableResult
    func removeReferences(to context: Context) -> [ObjectIdentifier] {
        let keys = contexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in keys {
            contexts.removeValue(forKey: key)
        }
        return keys
    }

    /// Rebinds a context to a window while preserving duplicate-window conflict behavior.
    ///
    /// Returns `true` only when a new index entry was installed. A conflicting entry leaves
    /// the context unindexed under the requested key, matching the prior AppDelegate logic.
    @discardableResult
    func reindex(_ context: Context, for window: NSWindow) -> Bool {
        let desiredKey = ObjectIdentifier(window)
        if contexts[desiredKey] === context {
            context.window = window
            return false
        }

        removeReferences(to: context)

        if let conflicting = contexts[desiredKey], conflicting !== context {
            context.window = window
            return false
        }

        contexts[desiredKey] = context
        context.window = window
        return true
    }
}
