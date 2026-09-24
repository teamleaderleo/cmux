public import AppKit
public import Foundation

/// Marks a pane rect for a profile's foreign window.
///
/// The view leases the profile from the registry while it exists; it never
/// owns the process, so view teardown (pane moves, split drags, workspace
/// moves) only detaches. While visible it shows one of three states: the
/// external window sits over it, an Accessibility prompt, or a placeholder
/// saying another pane shows the profile.
///
/// The external window covers the view minus a thin bar along the bottom
/// edge. While the window is presented there, the bar offers "Paste Claude
/// sign-in link", which sends a copied `claude://` sign-in link to exactly
/// this profile's process (see ``ClaudeDesktopSignInLinkDelivery``).
///
/// Call ``update(isFocused:isVisibleInUI:backgroundColor:)`` whenever pane
/// state changes and ``detach()`` on teardown. SwiftUI callers use
/// ``ForeignWindowSurface``, which does both.
@MainActor
public final class ForeignWindowHostView: NSView, ForeignWindowProfileHost {
    private static let observedHostWindowNotifications: [Notification.Name] = [
        NSWindow.didMoveNotification,
        NSWindow.didResizeNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification,
        NSWindow.didChangeScreenNotification,
        NSWindow.didBecomeKeyNotification
    ]

    private let hostID = UUID()
    private let panelID: UUID
    private let profile: String
    private let registry: ForeignWindowProfileRegistry
    private let accessibility: ForeignWindowAccessibility
    private let placeholderLabel: NSTextField
    private let accessStack = NSStackView()
    private let signInLinkBar = ForeignWindowSignInLinkBar()
    private var isAttached = false
    private var isDetached = false
    private var isPresenting = false
    private var isFocused = false
    private var isVisibleInUI = false
    private var lastReportedVisibility = false
    private weak var observedHostWindow: NSWindow?
    /// Called when the user clicks the placeholder; the host app should focus
    /// this pane, which moves the external window here.
    public var onRequestPanelFocus: (() -> Void)?

    /// Creates a host view for one pane.
    ///
    /// - Parameter panelID: The panel that claims `profile` in `registry`.
    /// - Parameter profile: The profile whose window this pane shows.
    /// - Parameter registry: The registry the view leases from.
    /// - Parameter accessibility: The trust gate the sessions use.
    public init(
        panelID: UUID,
        profile: String,
        registry: ForeignWindowProfileRegistry,
        accessibility: ForeignWindowAccessibility
    ) {
        self.panelID = panelID
        self.profile = profile
        self.registry = registry
        self.accessibility = accessibility
        self.placeholderLabel = NSTextField(
            wrappingLabelWithString: String(
                localized: "foreignWindow.placeholder.shownInOtherPane",
                defaultValue: "This account is open in another pane. Focus this pane to show it here.",
                bundle: .module
            )
        )
        super.init(frame: .zero)
        wantsLayer = true
        configurePlaceholder()
        configureAccessPrompt()
        configureSignInLinkBar()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cmuxApplicationBecameActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityAccessChanged(_:)),
            name: ForeignWindowAccessibility.didChangeNotification,
            object: accessibility
        )
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var isOpaque: Bool { true }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installHostWindowObservers()
        syncPresentation(raiseExternalWindow: isFocused)
    }

    override public func mouseDown(with event: NSEvent) {
        if !isPresenting, accessibility.isTrusted {
            onRequestPanelFocus?()
        }
        super.mouseDown(with: event)
    }

    override public func layout() {
        super.layout()
        // Cheap: the session coalesces AX writes and skips unchanged rects.
        syncPresentation(raiseExternalWindow: false)
    }

    /// Reports pane state to the registry and restyles the view.
    ///
    /// - Parameter isFocused: Whether the pane has focus.
    /// - Parameter isVisibleInUI: Whether the pane is on screen in the host UI.
    /// - Parameter backgroundColor: Fill shown behind placeholders.
    public func update(
        isFocused: Bool,
        isVisibleInUI: Bool,
        backgroundColor: NSColor
    ) {
        let becameFocused = isFocused && !self.isFocused
        let becameVisible = isVisibleInUI && !self.isVisibleInUI
        self.isFocused = isFocused
        self.isVisibleInUI = isVisibleInUI
        layer?.backgroundColor = backgroundColor.cgColor
        syncPresentation(
            raiseExternalWindow: becameFocused || becameVisible
        )
    }

    /// View teardown: releases the lease only. The process keeps running
    /// until its panel releases the profile. Idempotent.
    public func detach() {
        guard !isDetached else { return }
        isDetached = true
        removeHostWindowObservers()
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.removeObserver(
            self,
            name: ForeignWindowAccessibility.didChangeNotification,
            object: accessibility
        )
        if isAttached {
            registry.detach(hostID: hostID)
            isAttached = false
        }
        isPresenting = false
        onRequestPanelFocus = nil
    }

    // MARK: ForeignWindowProfileHost

    /// Shows or hides the placeholder as the registry moves the window.
    ///
    /// - Parameter isPresenting: Whether the window now sits over this view.
    public func foreignWindowProfileHostDidChangePresenting(_ isPresenting: Bool) {
        self.isPresenting = isPresenting
        updatePlaceholderVisibility()
    }

    // MARK: Private

    private func configurePlaceholder() {
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.alignment = .center
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        placeholderLabel.isHidden = true
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: 16
            ),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -16
            )
        ])
    }

    private func configureAccessPrompt() {
        let message = NSTextField(
            wrappingLabelWithString: String(
                localized: "foreignWindow.accessibility.message",
                defaultValue: "cmux needs Accessibility access to place Claude in this pane.",
                bundle: .module
            )
        )
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: NSFont.systemFontSize)
        let button = NSButton(
            title: String(
                localized: "foreignWindow.accessibility.openSettings",
                defaultValue: "Open Accessibility Settings",
                bundle: .module
            ),
            target: self,
            action: #selector(requestAccessibilityAccess(_:))
        )
        button.bezelStyle = .rounded
        accessStack.orientation = .vertical
        accessStack.alignment = .centerX
        accessStack.spacing = 12
        accessStack.addArrangedSubview(message)
        accessStack.addArrangedSubview(button)
        accessStack.translatesAutoresizingMaskIntoConstraints = false
        accessStack.isHidden = true
        addSubview(accessStack)
        NSLayoutConstraint.activate([
            accessStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            accessStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: 16
            ),
            accessStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -16
            )
        ])
    }

    private func configureSignInLinkBar() {
        signInLinkBar.translatesAutoresizingMaskIntoConstraints = false
        signInLinkBar.isHidden = true
        signInLinkBar.onPaste = { [weak self] in
            self?.pasteSignInLink() ?? ForeignWindowSignInLinkBar.Status(message: "", isError: false)
        }
        addSubview(signInLinkBar)
        NSLayoutConstraint.activate([
            signInLinkBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            signInLinkBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            signInLinkBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            signInLinkBar.heightAnchor.constraint(
                equalToConstant: ForeignWindowSignInLinkBar.height
            )
        ])
    }

    private func pasteSignInLink() -> ForeignWindowSignInLinkBar.Status {
        let outcome = ClaudeDesktopSignInLinkDelivery.deliver(
            text: NSPasteboard.general.string(forType: .string),
            to: registry.processIdentifier(forProfile: profile)
        ) { url, processIdentifier in
            try ForeignWindowURLEvent.send(url, to: processIdentifier)
        }
        switch outcome {
        case .sent:
            return ForeignWindowSignInLinkBar.Status(
                message: String(
                    localized: "foreignWindow.signInLink.sent",
                    defaultValue: "Sign-in link sent to Claude.",
                    bundle: .module
                ),
                isError: false
            )
        case .notSignInLink:
            return ForeignWindowSignInLinkBar.Status(
                message: String(
                    localized: "foreignWindow.signInLink.invalid",
                    defaultValue: "The clipboard does not hold a Claude sign-in link.",
                    bundle: .module
                ),
                isError: true
            )
        case .claudeNotRunning:
            return ForeignWindowSignInLinkBar.Status(
                message: String(
                    localized: "foreignWindow.signInLink.notRunning",
                    defaultValue: "Claude is not running in this pane.",
                    bundle: .module
                ),
                isError: true
            )
        case .sendFailed:
            return ForeignWindowSignInLinkBar.Status(
                message: String(
                    localized: "foreignWindow.signInLink.sendFailed",
                    defaultValue: "Could not send the link to Claude.",
                    bundle: .module
                ),
                isError: true
            )
        }
    }

    /// One of three states while visible: the app's window sits over the
    /// pane, Accessibility is missing (prompt), or another pane shows it.
    private func updatePlaceholderVisibility() {
        let needsAccess = lastReportedVisibility
            && isAttached
            && !accessibility.isTrusted
        let shouldShowPlaceholder = lastReportedVisibility
            && isAttached
            && !isPresenting
            && !needsAccess
        if accessStack.isHidden == needsAccess {
            accessStack.isHidden = !needsAccess
        }
        if placeholderLabel.isHidden == shouldShowPlaceholder {
            placeholderLabel.isHidden = !shouldShowPlaceholder
        }
        // The bar belongs to a presented window; the prompt and placeholder
        // stand alone.
        let shouldShowBar = lastReportedVisibility
            && isAttached
            && isPresenting
            && !needsAccess
        if signInLinkBar.isHidden == shouldShowBar {
            signInLinkBar.isHidden = !shouldShowBar
            if !shouldShowBar {
                signInLinkBar.clearStatus()
                if window?.firstResponder === signInLinkBar {
                    window?.makeFirstResponder(nil)
                }
            }
        }
    }

    @objc private func requestAccessibilityAccess(_ sender: Any?) {
        _ = sender
        accessibility.requestAccess()
    }

    @objc private func accessibilityAccessChanged(_ notification: Notification) {
        _ = notification
        syncPresentation(raiseExternalWindow: true)
    }

    private func attachIfNeeded() {
        guard !isAttached, !isDetached else { return }
        registry.attach(
            host: self,
            hostID: hostID,
            panelID: panelID,
            profile: profile
        )
        isAttached = true
    }

    private func installHostWindowObservers() {
        guard observedHostWindow !== window else { return }
        removeHostWindowObservers()
        guard let window, !isDetached else { return }
        observedHostWindow = window
        let center = NotificationCenter.default
        for name in Self.observedHostWindowNotifications {
            center.addObserver(
                self,
                selector: #selector(hostWindowChanged(_:)),
                name: name,
                object: window
            )
        }
    }

    private func removeHostWindowObservers() {
        guard let observedHostWindow else { return }
        let center = NotificationCenter.default
        for name in Self.observedHostWindowNotifications {
            center.removeObserver(
                self,
                name: name,
                object: observedHostWindow
            )
        }
        self.observedHostWindow = nil
    }

    @objc private func hostWindowChanged(_ notification: Notification) {
        let shouldRaise = notification.name == NSWindow.didBecomeKeyNotification
            || notification.name == NSWindow.didDeminiaturizeNotification
        syncPresentation(raiseExternalWindow: shouldRaise)
        if notification.name == NSWindow.didBecomeKeyNotification {
            orderHostWindowBelowHostedWindows()
        }
    }

    @objc private func cmuxApplicationBecameActive(_ notification: Notification) {
        _ = notification
        syncPresentation(raiseExternalWindow: true)
        orderHostWindowBelowHostedWindows()
    }

    /// Activating the host app stacks its window above the hosted apps'
    /// windows, covering them. Push the host window back underneath each one.
    /// Ordering below each window in turn only ever moves the host window
    /// down, so it ends below all of them. Deferred one turn so it runs after
    /// AppKit finishes the activation's own ordering.
    private func orderHostWindowBelowHostedWindows() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isDetached, let window = self.window else { return }
                for number in self.registry.presentedForeignWindowNumbers() {
                    window.order(.below, relativeTo: number)
                }
            }
        }
    }

    private func syncPresentation(raiseExternalWindow: Bool) {
        guard !isDetached else { return }
        attachIfNeeded()
        let hostWindowVisible = window?.isVisible == true
            && window?.isMiniaturized == false
        let shouldShow = isVisibleInUI && hostWindowVisible
        lastReportedVisibility = shouldShow
        registry.updateHost(
            hostID: hostID,
            isVisible: shouldShow,
            isFocused: isFocused,
            targetFrame: shouldShow ? accessibilityScreenFrame() : nil,
            raiseWindow: raiseExternalWindow
        )
        updatePlaceholderVisibility()
    }

    /// The part of the view the external window covers: everything above the
    /// sign-in link bar. Reserved even while the bar is hidden, so a host that
    /// starts presenting never moves the window twice.
    private var externalWindowRect: NSRect {
        var rect = bounds
        let barHeight = min(ForeignWindowSignInLinkBar.height, rect.height)
        if isFlipped {
            rect.size.height -= barHeight
        } else {
            rect.origin.y += barHeight
            rect.size.height -= barHeight
        }
        return rect
    }

    private func accessibilityScreenFrame() -> CGRect? {
        guard let window else { return nil }
        let windowRect = convert(externalWindowRect, to: nil)
        let appKitScreenRect = window.convertToScreen(windowRect)
        guard appKitScreenRect.width >= 1,
              appKitScreenRect.height >= 1 else {
            return nil
        }

        // AppKit uses a bottom-left global origin while AX window coordinates
        // use a top-left origin relative to the primary display.
        let primaryScreenTop = NSScreen.screens.first?.frame.maxY
            ?? appKitScreenRect.maxY
        return CGRect(
            x: appKitScreenRect.minX,
            y: primaryScreenTop - appKitScreenRect.maxY,
            width: appKitScreenRect.width,
            height: appKitScreenRect.height
        )
    }
}
