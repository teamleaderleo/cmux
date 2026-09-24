import AppKit
import ApplicationServices
public import Foundation

/// Owns one external application process (one per profile) and glues its
/// main window over whichever host rect the registry says is presenting.
///
/// AX writes are cross-process IPC, so presentation updates are coalesced to
/// one apply per main run loop turn and skipped when the target is unchanged.
///
/// The session launches its app lazily on the first visible presentation,
/// keeps it hidden while ``ForeignWindowAccessibility`` is untrusted or the
/// ``ForeignWindowYieldCoordinator`` is yielding, and terminates it in
/// ``invalidate()``. Build one per profile from a
/// ``ForeignWindowProfileRegistry`` session factory:
///
/// ```swift
/// let registry = ForeignWindowProfileRegistry { profile in
///     ForeignWindowSession(
///         identifier: "claude:\(profile)",
///         launchConfiguration: store.launchConfiguration(profile: profile),
///         accessibility: accessibility,
///         yieldCoordinator: yieldCoordinator,
///         processLedger: ledger
///     )
/// }
/// ```
@MainActor
public final class ForeignWindowSession: ForeignWindowProfileSession {
    /// Forwards AX notifications to the session passed as the refcon.
    ///
    /// The refcon is a +1 reference the session takes when it installs the
    /// observer and drops only after removing the observer's run loop source,
    /// so the pointer is always valid here. A non-capturing closure converts
    /// to the `@convention(c)` callback AXObserver requires.
    private static let accessibilityCallback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let session = Unmanaged<ForeignWindowSession>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        let name = notification as String
        if Thread.isMainThread {
            // The source is added to the main run loop, so this is the usual path.
            MainActor.assumeIsolated {
                session.handleAccessibilityNotification(name)
            }
        } else {
            Task { @MainActor in
                session.handleAccessibilityNotification(name)
            }
        }
    }

    private static let frameTolerance: CGFloat = 1
    /// Snap-back attempts per target rect, so an app that enforces its own
    /// minimum size cannot put us in a set/notify loop.
    private static let maximumCorrectionsPerTarget = 3
    private static let windowNotificationNames: [String] = [
        kAXMovedNotification,
        kAXResizedNotification,
        kAXUIElementDestroyedNotification
    ]

    private let identifier: String
    private let launchConfiguration: ForeignWindowLaunchConfiguration
    private let accessibility: ForeignWindowAccessibility
    private let yieldCoordinator: ForeignWindowYieldCoordinator
    private let processLedger: ForeignWindowProcessLedger?
    private let logger: ForeignWindowLogger
    private var launchTask: Task<Void, Never>?
    private var isLaunchAllowed = true
    private var isInvalidated = false

    private var runningApplication: NSRunningApplication? {
        didSet {
            processLedger?.replace(
                oldValue?.processIdentifier,
                with: runningApplication?.processIdentifier
            )
        }
    }
    private var applicationElement: AXUIElement?
    private var externalWindow: AXUIElement?
    private var observedWindow: AXUIElement?
    private var accessibilityObserver: AXObserver?
    private var observerRefcon: Unmanaged<ForeignWindowSession>?
    private var accessibilityObserverToken: (any NSObjectProtocol)?

    private var targetFrame: CGRect?
    private var shouldBeVisible = false
    private var shouldBeFocused = false
    private var lastAppliedFrame: CGRect?
    private var correctionsForTarget = 0
    private var pendingActivate = false
    private var pendingRaise = false
    private var isApplyScheduled = false
    private var isBindingRetryScheduled = false
    private var bindingRetryCount = 0
    private static let maxBindingRetries = 120

    private var yieldObserver: (any NSObjectProtocol)?
    private var isHiddenForYield = false
    /// `NSRunningApplication.isHidden` updates asynchronously, so remember
    /// that we asked for a hide and always pair it with an unhide.
    private var didRequestHide = false

    /// Creates a session. Nothing launches until a visible presentation.
    ///
    /// - Parameter identifier: Diagnostic name, for example `claude:work`.
    /// - Parameter launchConfiguration: How to find and launch the app.
    /// - Parameter accessibility: Trust gate shared by every session.
    /// - Parameter yieldCoordinator: Hides the window while host UI floats.
    /// - Parameter processLedger: Records the launched process, when given.
    /// - Parameter logger: Receives lifecycle diagnostics.
    public init(
        identifier: String,
        launchConfiguration: ForeignWindowLaunchConfiguration,
        accessibility: ForeignWindowAccessibility,
        yieldCoordinator: ForeignWindowYieldCoordinator,
        processLedger: ForeignWindowProcessLedger? = nil,
        logger: ForeignWindowLogger = .disabled
    ) {
        self.identifier = identifier
        self.launchConfiguration = launchConfiguration
        self.accessibility = accessibility
        self.yieldCoordinator = yieldCoordinator
        self.processLedger = processLedger
        self.logger = logger
        accessibility.beginInterest()
        accessibilityObserverToken = NotificationCenter.default.addObserver(
            forName: ForeignWindowAccessibility.didChangeNotification,
            object: accessibility,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A fresh grant: bind the window and place it over the pane.
                self.lastAppliedFrame = nil
                self.pendingRaise = true
                self.scheduleApply()
            }
        }
        yieldObserver = NotificationCenter.default.addObserver(
            forName: ForeignWindowYieldCoordinator.didChangeNotification,
            object: yieldCoordinator,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.yieldStateDidChange()
            }
        }
    }

    /// Whether the launched app is still running.
    public var isRunning: Bool {
        guard let runningApplication else { return false }
        return !runningApplication.isTerminated
    }

    /// The launched app's process, while it runs.
    public var processIdentifier: pid_t? {
        guard let runningApplication, !runningApplication.isTerminated else { return nil }
        return runningApplication.processIdentifier
    }

    private var isYielding: Bool {
        yieldCoordinator.isYielding
    }

    /// Records the presenting host's state and schedules one coalesced apply.
    ///
    /// - Parameter targetFrame: Screen rect in Accessibility coordinates.
    /// - Parameter isVisible: Whether the window should be shown.
    /// - Parameter isFocused: Whether the app should be activated.
    /// - Parameter raiseWindow: Whether to raise the window.
    public func updatePresentation(
        targetFrame: CGRect?,
        isVisible: Bool,
        isFocused: Bool,
        raiseWindow: Bool
    ) {
        guard !isInvalidated else { return }
        let becameFocused = isFocused && !shouldBeFocused
        let becameVisible = isVisible && !shouldBeVisible
        if targetFrame != self.targetFrame {
            correctionsForTarget = 0
        }
        self.targetFrame = targetFrame
        shouldBeVisible = isVisible
        shouldBeFocused = isFocused
        pendingActivate = pendingActivate || becameFocused
        pendingRaise = pendingRaise || raiseWindow || becameVisible
        if becameVisible || becameFocused {
            // Allow one relaunch per explicit show after the user quit the app.
            isLaunchAllowed = true
        }
        scheduleApply()
    }

    /// Removes observers and terminates the launched app. Idempotent.
    public func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        launchTask?.cancel()
        launchTask = nil
        if let yieldObserver {
            NotificationCenter.default.removeObserver(yieldObserver)
        }
        yieldObserver = nil
        if let accessibilityObserverToken {
            NotificationCenter.default.removeObserver(accessibilityObserverToken)
            accessibility.endInterest()
        }
        accessibilityObserverToken = nil
        removeAccessibilityObserver()
        externalWindow = nil
        applicationElement = nil

        if let runningApplication, !runningApplication.isTerminated {
            runningApplication.terminate()
        }
        runningApplication = nil
    }

    fileprivate func handleAccessibilityNotification(_ name: String) {
        guard !isInvalidated else { return }
        switch name {
        case kAXWindowCreatedNotification:
            guard refreshExternalWindow() else { return }
            lastAppliedFrame = nil
            pendingRaise = true
            pendingActivate = pendingActivate || shouldBeFocused
            scheduleApply()
        case kAXUIElementDestroyedNotification:
            unregisterWindowNotifications()
            externalWindow = nil
            lastAppliedFrame = nil
            if refreshExternalWindow() {
                pendingRaise = true
                scheduleApply()
            }
        case kAXMovedNotification, kAXResizedNotification:
            snapBackIfDisplaced()
        default:
            break
        }
    }

    // MARK: Coalesced apply

    private func scheduleApply() {
        guard !isApplyScheduled, !isInvalidated else { return }
        isApplyScheduled = true
        // Coalesces AX writes to one per main run loop turn. The main queue
        // drains in common modes, including event tracking, so this also runs
        // once per turn during divider drags; a Task would not.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.flushPresentation()
            }
        }
    }

    private func flushPresentation() {
        isApplyScheduled = false
        guard !isInvalidated else { return }
        if let runningApplication, runningApplication.isTerminated {
            handleApplicationTerminated()
        }
        guard runningApplication != nil else {
            if shouldBeVisible {
                startIfNeeded()
            }
            return
        }
        ensureAccessibilityBinding()
        applyPresentation()
    }

    private func yieldStateDidChange() {
        guard !isInvalidated, let runningApplication,
              !runningApplication.isTerminated else {
            return
        }
        if isYielding {
            // Hide immediately so floating cmux UI is never covered.
            if shouldBeVisible {
                hideApplication(runningApplication)
                isHiddenForYield = true
            }
        } else if isHiddenForYield {
            isHiddenForYield = false
            // Restore and re-raise without activating the external app.
            pendingRaise = true
            scheduleApply()
        }
    }

    // MARK: Launch

    private func startIfNeeded() {
        guard !isInvalidated,
              isLaunchAllowed,
              launchTask == nil,
              runningApplication == nil else {
            return
        }
        isLaunchAllowed = false

        guard let applicationURL = resolveApplicationURL() else {
            logger(
                "foreignWindow.appMissing id=\(identifier) "
                    + "bundle=\(launchConfiguration.bundleIdentifier)"
            )
            return
        }
        guard prepareLaunchDirectories() else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.hides = true
        configuration.addsToRecentItems = false
        configuration.arguments = launchConfiguration.arguments
        if !launchConfiguration.environment.isEmpty {
            configuration.environment = launchConfiguration.environment
        }

        launchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.launchTask = nil }
            do {
                let application = try await NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                )
                guard !Task.isCancelled, !self.isInvalidated else {
                    application.terminate()
                    return
                }
                self.runningApplication = application
                // Launched with `hides = true`.
                self.didRequestHide = true
                self.lastAppliedFrame = nil
                self.pendingRaise = true
                self.pendingActivate = self.shouldBeFocused
                self.scheduleApply()
            } catch {
                logger(
                    "foreignWindow.launchFailed id=\(self.identifier) "
                        + "bundle=\(self.launchConfiguration.bundleIdentifier) "
                        + "error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func handleApplicationTerminated() {
        logger("foreignWindow.appTerminated id=\(identifier)")
        removeAccessibilityObserver()
        externalWindow = nil
        applicationElement = nil
        runningApplication = nil
        lastAppliedFrame = nil
        isHiddenForYield = false
        didRequestHide = false
    }

    private func resolveApplicationURL() -> URL? {
        let fileManager = FileManager.default
        if let preferredApplicationURL = launchConfiguration.preferredApplicationURL,
           fileManager.fileExists(atPath: preferredApplicationURL.path) {
            return preferredApplicationURL
        }

        if let installedURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: launchConfiguration.bundleIdentifier
        ) {
            return installedURL
        }

        return launchConfiguration.fallbackApplicationURLs.first {
            fileManager.fileExists(atPath: $0.path)
        }
    }

    private func prepareLaunchDirectories() -> Bool {
        for directoryURL in launchConfiguration.directoriesToCreate {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
            } catch {
                logger(
                    "foreignWindow.directoryCreateFailed id=\(identifier) "
                        + "path=\(directoryURL.path) error=\(error.localizedDescription)"
                )
                return false
            }
        }
        return true
    }

    // MARK: Accessibility binding

    private func ensureAccessibilityBinding() {
        guard let runningApplication, !runningApplication.isTerminated else { return }

        guard accessibility.isTrusted else {
            // Shows the system prompt once per launch; later requests come
            // from the pane's "Open Accessibility Settings" button.
            accessibility.requestAccess()
            return
        }

        if applicationElement == nil {
            let element = AXUIElementCreateApplication(
                runningApplication.processIdentifier
            )
            // Electron (Claude Desktop) builds its accessibility tree only when
            // asked; without this, window queries can fail or come back empty.
            _ = AXUIElementSetAttributeValue(
                element,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
            applicationElement = element
        }

        installAccessibilityObserverIfNeeded()
        if externalWindow == nil {
            _ = refreshExternalWindow()
        }
        scheduleBindingRetryIfNeeded()
    }

    /// A freshly launched app answers Accessibility with "cannot complete"
    /// until it is ready, and nothing else re-triggers binding after launch.
    /// Retry every half second until the observer and a window are bound.
    private func scheduleBindingRetryIfNeeded() {
        let isBound = accessibilityObserver != nil && externalWindow != nil
        if isBound {
            bindingRetryCount = 0
            return
        }
        guard !isBindingRetryScheduled,
              bindingRetryCount < Self.maxBindingRetries else { return }
        isBindingRetryScheduled = true
        bindingRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isInvalidated else { return }
                self.isBindingRetryScheduled = false
                self.lastAppliedFrame = nil
                self.pendingRaise = true
                self.scheduleApply()
            }
        }
    }

    private func installAccessibilityObserverIfNeeded() {
        guard accessibilityObserver == nil,
              let applicationElement,
              let runningApplication else {
            return
        }

        var observer: AXObserver?
        let createResult = AXObserverCreate(
            runningApplication.processIdentifier,
            Self.accessibilityCallback,
            &observer
        )
        guard createResult == .success, let observer else {
            logger(
                "foreignWindow.axObserverCreateFailed id=\(identifier) "
                    + "code=\(createResult.rawValue)"
            )
            return
        }

        let refcon = Unmanaged.passRetained(self)
        let notificationResult = AXObserverAddNotification(
            observer,
            applicationElement,
            kAXWindowCreatedNotification as CFString,
            refcon.toOpaque()
        )
        guard notificationResult == .success
                || notificationResult == .notificationAlreadyRegistered else {
            refcon.release()
            logger(
                "foreignWindow.axObserverAddFailed id=\(identifier) "
                    + "code=\(notificationResult.rawValue)"
            )
            return
        }

        accessibilityObserver = observer
        observerRefcon = refcon
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    private func removeAccessibilityObserver() {
        guard let accessibilityObserver else { return }
        unregisterWindowNotifications()
        if let applicationElement {
            _ = AXObserverRemoveNotification(
                accessibilityObserver,
                applicationElement,
                kAXWindowCreatedNotification as CFString
            )
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(accessibilityObserver),
            .commonModes
        )
        self.accessibilityObserver = nil
        // Balance the +1 taken at install only after the source is gone.
        observerRefcon?.release()
        observerRefcon = nil
    }

    private func registerWindowNotifications(_ window: AXUIElement) {
        if let observedWindow, CFEqual(observedWindow, window) { return }
        unregisterWindowNotifications()
        guard let accessibilityObserver, let observerRefcon else { return }
        for name in Self.windowNotificationNames {
            let result = AXObserverAddNotification(
                accessibilityObserver,
                window,
                name as CFString,
                observerRefcon.toOpaque()
            )
            if result != .success, result != .notificationAlreadyRegistered {
                logger(
                    "foreignWindow.axWindowObserveFailed id=\(identifier) "
                        + "name=\(name) code=\(result.rawValue)"
                )
            }
        }
        observedWindow = window
    }

    private func unregisterWindowNotifications() {
        guard let observedWindow else { return }
        if let accessibilityObserver {
            for name in Self.windowNotificationNames {
                _ = AXObserverRemoveNotification(
                    accessibilityObserver,
                    observedWindow,
                    name as CFString
                )
            }
        }
        self.observedWindow = nil
    }

    @discardableResult
    private func refreshExternalWindow() -> Bool {
        guard let applicationElement,
              let preferredWindow = preferredExternalWindow(applicationElement) else {
            return false
        }
        if let externalWindow, CFEqual(externalWindow, preferredWindow) {
            registerWindowNotifications(preferredWindow)
            return true
        }
        externalWindow = preferredWindow
        lastAppliedFrame = nil
        registerWindowNotifications(preferredWindow)
        return true
    }

    private func preferredExternalWindow(
        _ applicationElement: AXUIElement
    ) -> AXUIElement? {
        let windows = axWindows(applicationElement)
        let standardWindows = windows.filter {
            axString($0, kAXSubroleAttribute) == kAXStandardWindowSubrole
        }
        return (standardWindows.isEmpty ? windows : standardWindows)
            .max { lhs, rhs in
                let lhsSize = axSize(lhs)
                let rhsSize = axSize(rhs)
                return lhsSize.width * lhsSize.height
                    < rhsSize.width * rhsSize.height
            }
    }

    // MARK: Presentation

    private func applyPresentation() {
        guard let runningApplication, !runningApplication.isTerminated else { return }

        // Without Accessibility the window cannot be placed over the pane, so
        // keep the app hidden instead of letting it float over cmux.
        guard accessibility.isTrusted else {
            hideApplication(runningApplication)
            return
        }

        guard shouldBeVisible, !isYielding else {
            if shouldBeVisible {
                isHiddenForYield = true
            }
            hideApplication(runningApplication)
            return
        }

        guard let targetFrame else { return }
        if externalWindow == nil {
            _ = refreshExternalWindow()
        }
        guard let window = externalWindow else { return }
        // Consume raise/activate only once there is a window to act on; the
        // window-created notification re-requests them otherwise.
        let activate = pendingActivate
        let raise = pendingRaise
        pendingActivate = false
        pendingRaise = false

        if lastAppliedFrame != targetFrame {
            if setExternalWindowFrame(targetFrame, window: window, previous: lastAppliedFrame) {
                lastAppliedFrame = targetFrame
            } else {
                // The window may have been replaced; rebind and retry once.
                unregisterWindowNotifications()
                externalWindow = nil
                guard refreshExternalWindow(),
                      let replacementWindow = externalWindow,
                      setExternalWindowFrame(targetFrame, window: replacementWindow, previous: nil) else {
                    return
                }
                lastAppliedFrame = targetFrame
            }
        }

        guard let boundWindow = externalWindow else { return }
        if raise {
            _ = AXUIElementSetAttributeValue(
                boundWindow,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }
        if didRequestHide || runningApplication.isHidden {
            _ = runningApplication.unhide()
            didRequestHide = false
        }
        isHiddenForYield = false
        if raise {
            _ = AXUIElementPerformAction(boundWindow, kAXRaiseAction as CFString)
        }
        if activate && shouldBeFocused {
            _ = runningApplication.activate(options: [.activateAllWindows])
            _ = AXUIElementPerformAction(boundWindow, kAXRaiseAction as CFString)
        }
    }

    private func hideApplication(_ runningApplication: NSRunningApplication) {
        if !runningApplication.isHidden {
            _ = runningApplication.hide()
        }
        didRequestHide = true
    }

    /// Re-applies the target rect when the external window moved or resized
    /// itself. Our own writes also produce these notifications; by the time
    /// they arrive the window already sits at the rect we wrote, so they fall
    /// through the equality check instead of looping.
    private func snapBackIfDisplaced() {
        guard shouldBeVisible,
              !isYielding,
              let targetFrame,
              lastAppliedFrame == targetFrame,
              let window = externalWindow,
              let currentFrame = axFrame(window) else {
            return
        }
        guard !Self.frame(currentFrame, approximatelyEquals: targetFrame) else {
            return
        }
        guard correctionsForTarget < Self.maximumCorrectionsPerTarget else { return }
        correctionsForTarget += 1
        logger(
            "foreignWindow.snapBack id=\(identifier) attempt=\(correctionsForTarget) "
                + "current=\(currentFrame) target=\(targetFrame)"
        )
        lastAppliedFrame = nil
        scheduleApply()
    }

    private static func frame(
        _ lhs: CGRect,
        approximatelyEquals rhs: CGRect
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= frameTolerance
            && abs(lhs.minY - rhs.minY) <= frameTolerance
            && abs(lhs.width - rhs.width) <= frameTolerance
            && abs(lhs.height - rhs.height) <= frameTolerance
    }

    /// Writes only the parts of the frame that changed. A move (host window
    /// dragged) is then one cheap position write; only a real size change
    /// makes the hosted app lay out and redraw.
    private func setExternalWindowFrame(
        _ frame: CGRect,
        window: AXUIElement,
        previous: CGRect?
    ) -> Bool {
        var result = true
        if previous?.size != frame.size {
            var size = frame.size
            guard let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
            result = AXUIElementSetAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                sizeValue
            ) == .success && result
        }
        if previous?.origin != frame.origin {
            var position = frame.origin
            guard let positionValue = AXValueCreate(.cgPoint, &position) else { return false }
            result = AXUIElementSetAttributeValue(
                window,
                kAXPositionAttribute as CFString,
                positionValue
            ) == .success && result
        }
        return result
    }

    // MARK: AX reads

    private func copiedAXValue(
        _ element: AXUIElement,
        attribute: String
    ) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        guard result == .success else { return nil }
        return value
    }

    private func axWindows(_ applicationElement: AXUIElement) -> [AXUIElement] {
        guard let values = copiedAXValue(
            applicationElement,
            attribute: kAXWindowsAttribute
        ) as? [AnyObject] else {
            return []
        }
        return values.compactMap {
            unsafeBitCast($0, to: AXUIElement?.self)
        }
    }

    private func axString(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        copiedAXValue(element, attribute: attribute) as? String
    }

    private func axSize(_ element: AXUIElement) -> CGSize {
        guard let value = copiedAXValue(
            element,
            attribute: kAXSizeAttribute
        ) else {
            return .zero
        }
        var size = CGSize.zero
        AXValueGetValue(
            unsafeDowncast(value, to: AXValue.self),
            .cgSize,
            &size
        )
        return size
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = copiedAXValue(
            element,
            attribute: kAXPositionAttribute
        ), let sizeValue = copiedAXValue(
            element,
            attribute: kAXSizeAttribute
        ) else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(
            unsafeDowncast(positionValue, to: AXValue.self),
            .cgPoint,
            &position
        ), AXValueGetValue(
            unsafeDowncast(sizeValue, to: AXValue.self),
            .cgSize,
            &size
        ) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }
}
