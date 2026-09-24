import AppKit

/// The thin strip under a hosted Claude window with "Paste Claude sign-in link".
///
/// It sits below the rect the external window covers, so it is always
/// clickable. The strip takes key focus when clicked; Cmd-V (or Edit > Paste)
/// then triggers the same paste as the button.
@MainActor
final class ForeignWindowSignInLinkBar: NSView {
    /// Height the host view reserves for the bar.
    static let height: CGFloat = 28
    private static let statusDuration: Duration = .seconds(6)

    private static var helpText: String {
        String(
            localized: "foreignWindow.signInLink.help",
            defaultValue: "In the browser, right-click “Open Claude” and choose Copy Link, then click Paste Claude sign-in link.",
            bundle: .module
        )
    }

    /// Runs when the user asks to paste; returns the status to show.
    var onPaste: (() -> Status)?

    /// Inline feedback after a paste.
    struct Status {
        let message: String
        let isError: Bool
    }

    private let statusLabel = NSTextField(labelWithString: "")
    private var statusClearTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           window?.firstResponder === self {
            runPaste()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Edit > Paste while the bar is first responder.
    @objc func paste(_ sender: Any?) {
        _ = sender
        runPaste()
    }

    /// Clears any status, for example when the bar is hidden.
    func clearStatus() {
        statusClearTask?.cancel()
        statusClearTask = nil
        statusLabel.stringValue = ""
    }

    private func configure() {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let pasteButton = NSButton(
            title: String(
                localized: "foreignWindow.signInLink.paste",
                defaultValue: "Paste Claude sign-in link",
                bundle: .module
            ),
            target: self,
            action: #selector(pasteButtonClicked(_:))
        )
        pasteButton.bezelStyle = .accessoryBarAction
        pasteButton.controlSize = .small
        pasteButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pasteButton.contentTintColor = .secondaryLabelColor

        let helpText = Self.helpText
        let helpButton = NSButton(
            title: "",
            target: self,
            action: #selector(helpButtonClicked(_:))
        )
        helpButton.bezelStyle = .helpButton
        helpButton.controlSize = .mini
        helpButton.toolTip = helpText
        helpButton.setAccessibilityLabel(
            String(
                localized: "foreignWindow.signInLink.helpLabel",
                defaultValue: "How to get a sign-in link",
                bundle: .module
            )
        )
        helpButton.setAccessibilityHelp(helpText)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [pasteButton, helpButton, statusLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(stack)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func pasteButtonClicked(_ sender: Any?) {
        _ = sender
        // Keep focus here so a following Cmd-V also works.
        window?.makeFirstResponder(self)
        runPaste()
    }

    @objc private func helpButtonClicked(_ sender: Any?) {
        _ = sender
        show(Status(message: Self.helpText, isError: false))
    }

    private func runPaste() {
        guard let status = onPaste?() else { return }
        show(status)
    }

    private func show(_ status: Status) {
        statusLabel.stringValue = status.message
        statusLabel.textColor = status.isError ? .systemRed : .secondaryLabelColor
        statusLabel.toolTip = status.message
        statusClearTask?.cancel()
        statusClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.statusDuration)
            guard !Task.isCancelled else { return }
            self?.statusLabel.stringValue = ""
            self?.statusLabel.toolTip = nil
        }
    }
}
