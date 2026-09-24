public import Foundation

/// The object graph that hosts Claude Desktop profiles in panes.
///
/// Builds one ``ForeignWindowAccessibility`` gate, one
/// ``ForeignWindowYieldCoordinator``, one ``ForeignWindowProcessLedger``, a
/// ``ForeignWindowProfileRegistry`` whose sessions launch Claude with a
/// per-profile `--user-data-dir`, and, when given a handler app, a
/// ``ClaudeDesktopLinkRouter`` that claims the `claude` scheme while any
/// pane-owned Claude runs. The host app constructs one at its composition root.
///
/// ```swift
/// let hosting = ClaudeDesktopHosting(
///     store: ClaudeDesktopProfileStore(
///         homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
///         environment: ProcessInfo.processInfo.environment
///     ),
///     linkHandlerApplicationURL: Bundle.main.bundleURL
/// )
/// hosting.registry.claim(profile: "work", panelID: panel.id)
/// ```
@MainActor
public final class ClaudeDesktopHosting {
    /// Profile locations and launch configuration.
    public let store: ClaudeDesktopProfileStore
    /// The Accessibility gate every session and host view shares.
    public let accessibility: ForeignWindowAccessibility
    /// Hides hosted windows while host UI floats over panes.
    public let yieldCoordinator: ForeignWindowYieldCoordinator
    /// Claude processes launched for panes.
    public let processLedger: ForeignWindowProcessLedger
    /// Leases each profile's Claude process to the pane presenting it.
    public let registry: ForeignWindowProfileRegistry
    /// Routes `claude://` links, or `nil` when link routing is disabled.
    public let linkRouter: ClaudeDesktopLinkRouter?

    /// Builds the hosting graph.
    ///
    /// - Parameter store: Profile locations and launch configuration.
    /// - Parameter linkHandlerApplicationURL: The host app bundle to register as
    ///   the `claude` handler while it owns Claude processes. Pass `nil` to
    ///   leave the handler alone, as an unbundled executable must.
    /// - Parameter observesApplicationTermination: Terminates every Claude
    ///   process when the host app quits.
    /// - Parameter logger: Receives diagnostics from every component.
    public init(
        store: ClaudeDesktopProfileStore,
        linkHandlerApplicationURL: URL?,
        observesApplicationTermination: Bool = true,
        logger: ForeignWindowLogger = .disabled
    ) {
        let accessibility = ForeignWindowAccessibility()
        let yieldCoordinator = ForeignWindowYieldCoordinator()
        let processLedger = ForeignWindowProcessLedger()
        self.store = store
        self.accessibility = accessibility
        self.yieldCoordinator = yieldCoordinator
        self.processLedger = processLedger
        self.registry = ForeignWindowProfileRegistry(
            observesApplicationTermination: observesApplicationTermination,
            logger: logger
        ) { profile in
            ForeignWindowSession(
                identifier: "claude:\(profile)",
                launchConfiguration: store.launchConfiguration(profile: profile),
                accessibility: accessibility,
                yieldCoordinator: yieldCoordinator,
                processLedger: processLedger,
                logger: logger
            )
        }
        if let linkHandlerApplicationURL {
            let router = ClaudeDesktopLinkRouter(
                handlerApplicationURL: linkHandlerApplicationURL,
                processLedger: processLedger,
                logger: logger
            )
            processLedger.onChange = { [weak router] owned in
                if owned.isEmpty {
                    router?.releaseSchemeIfUnused()
                } else {
                    router?.claimSchemeIfNeeded()
                }
            }
            self.linkRouter = router
        } else {
            self.linkRouter = nil
        }
    }

    /// Every profile known on disk or in use, with its live state, sorted.
    ///
    /// - Parameter fileManager: File manager used to list the profile root.
    /// - Returns: One summary per profile name.
    public func profileSummaries(
        fileManager: FileManager = .default
    ) -> [ClaudeDesktopProfileSummary] {
        let onDisk = Set(store.profilesOnDisk(fileManager: fileManager))
        let inUse = registry.claimedProfiles
        let running = registry.runningProfiles
        return onDisk.union(inUse).union(running).sorted().map { name in
            ClaudeDesktopProfileSummary(
                name: name,
                existsOnDisk: onDisk.contains(name),
                isInUse: inUse.contains(name),
                isRunning: running.contains(name)
            )
        }
    }
}
