import AppKit
import CmuxTerminal
import GhosttyKit

@_silgen_name("ghostty_surface_read_semantic_block")
private func cmuxGhosttyReadSemanticBlock(
    _ surface: ghostty_surface_t,
    _ x: Double,
    _ y: Double,
    _ result: UnsafeMutablePointer<ghostty_text_s>
) -> Bool

final class GhosttyPassthroughVisualEffectView: NSVisualEffectView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class TerminalLinkHoverIndicatorView: NSView {
    private let backdrop = GhosttyPassthroughVisualEffectView(frame: .zero)
    private let label = NSTextField(labelWithString: "")

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 6
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        backdrop.alphaValue = 0.96

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(backdrop)
        backdrop.addSubview(label)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            backdrop.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func setURL(_ url: String?) {
        let url = url?.isEmpty == false ? url : nil
        label.stringValue = url ?? ""
        label.setAccessibilityLabel(url)
        isHidden = url == nil
    }
}

private final class TerminalSemanticHoverCopyView: NSView {
    private weak var surfaceView: GhosttyNSView?
    private let blockStartRule = NSView(frame: .zero)
    private let copyButton = NSButton(frame: .zero)
    private var tracking: NSTrackingArea?
    private var activeText: String?
    private var activeSummary = ""
    private var lastLookupTimestamp: TimeInterval = 0
    private var feedbackGeneration: UInt64 = 0

    private static let lookupInterval: TimeInterval = 0.04
    private static let buttonHeight: CGFloat = 26
    private static let minimumButtonWidth: CGFloat = 92
    private static let maximumButtonWidth: CGFloat = 280

    init(surfaceView: GhosttyNSView) {
        self.surfaceView = surfaceView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        blockStartRule.isHidden = true
        blockStartRule.wantsLayer = true
        blockStartRule.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        addSubview(blockStartRule)

        copyButton.isHidden = true
        copyButton.isBordered = false
        copyButton.imagePosition = .imageLeading
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        copyButton.alignment = .center
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.wantsLayer = true
        copyButton.layer?.cornerRadius = 6
        copyButton.layer?.borderWidth = 0
        copyButton.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
        copyButton.target = self
        copyButton.action = #selector(copyHoveredBlock)
        copyButton.setAccessibilityLabel("Copy terminal block")
        addSubview(copyButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !copyButton.isHidden else { return }
        addCursorRect(copyButton.frame.insetBy(dx: -4, dy: -4), cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !copyButton.isHidden else { return nil }
        let forgivingFrame = copyButton.frame.insetBy(dx: -4, dy: -4)
        return forgivingFrame.contains(point) ? copyButton : nil
    }

    override func mouseMoved(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if !copyButton.isHidden, copyButton.frame.insetBy(dx: -5, dy: -5).contains(localPoint) {
            return
        }

        guard event.timestamp - lastLookupTimestamp >= Self.lookupInterval else { return }
        lastLookupTimestamp = event.timestamp
        refreshSemanticBlock(at: event.locationInWindow, localPoint: localPoint)
    }

    override func mouseExited(with event: NSEvent) {
        hideSemanticBlock()
    }

    private func refreshSemanticBlock(at windowPoint: NSPoint, localPoint: NSPoint) {
        guard let surfaceView,
              let terminalSurface = surfaceView.terminalSurface,
              let surface = terminalSurface.surface else {
            hideSemanticBlock()
            return
        }

        let point = surfaceView.convert(windowPoint, from: nil)
        guard surfaceView.bounds.contains(point) else {
            hideSemanticBlock()
            return
        }

        var text = ghostty_text_s()
        guard cmuxGhosttyReadSemanticBlock(
            surface,
            Double(point.x),
            Double(surfaceView.bounds.height - point.y),
            &text
        ) else {
            hideSemanticBlock()
            return
        }
        defer { ghostty_surface_free_text(surface, &text) }

        guard text.text_len > 0,
              let bytes = text.text else {
            hideSemanticBlock()
            return
        }
        let data = Data(bytes: bytes, count: Int(text.text_len))
        guard let value = String(data: data, encoding: .utf8),
              !value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            hideSemanticBlock()
            return
        }

        let blockTopY = resolvedBlockTopY(text: text)
        if activeText == value {
            positionTarget(near: localPoint, blockTopY: blockTopY)
            return
        }

        activeText = value
        activeSummary = Self.summary(for: value)
        feedbackGeneration &+= 1
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton.title = "Copy · \(activeSummary)"
        copyButton.toolTip = "Copy this terminal block: \(activeSummary)"
        positionTarget(near: localPoint, blockTopY: blockTopY)
        copyButton.isHidden = false
        window?.invalidateCursorRects(for: self)
    }

    private func resolvedBlockTopY(text: ghostty_text_s) -> CGFloat? {
        guard text.tl_px_y.isFinite, text.tl_px_y >= 0 else { return nil }
        return min(max(0, bounds.height - CGFloat(text.tl_px_y)), bounds.height)
    }

    private func positionTarget(near point: NSPoint, blockTopY: CGFloat?) {
        copyButton.sizeToFit()
        let width = min(
            max(Self.minimumButtonWidth, copyButton.frame.width + 14),
            Self.maximumButtonWidth
        )
        let size = NSSize(width: width, height: Self.buttonHeight)
        let x = max(8, bounds.width - size.width - 10)

        let y: CGFloat
        if let blockTopY {
            let ruleY = min(max(8, blockTopY), max(8, bounds.height - 8))
            blockStartRule.frame = NSRect(
                x: 8,
                y: ruleY,
                width: max(0, bounds.width - 16),
                height: 1
            )
            blockStartRule.isHidden = false
            y = min(
                max(8, ruleY - size.height - 4),
                max(8, bounds.height - size.height - 8)
            )
        } else {
            blockStartRule.isHidden = true
            y = min(
                max(8, point.y - size.height / 2),
                max(8, bounds.height - size.height - 8)
            )
        }

        copyButton.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        window?.invalidateCursorRects(for: self)
    }

    private func hideSemanticBlock() {
        activeText = nil
        activeSummary = ""
        feedbackGeneration &+= 1
        blockStartRule.isHidden = true
        copyButton.isHidden = true
        window?.invalidateCursorRects(for: self)
    }

    @objc private func copyHoveredBlock() {
        guard let activeText else { return }
        GhosttyApp.terminalPasteboard.writeString(activeText, to: GHOSTTY_CLIPBOARD_STANDARD)

        feedbackGeneration &+= 1
        let generation = feedbackGeneration
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        copyButton.title = "Copied · \(activeSummary)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self,
                  self.feedbackGeneration == generation,
                  self.activeText != nil else { return }
            self.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            self.copyButton.title = "Copy · \(self.activeSummary)"
            self.positionTarget(near: self.copyButton.frame.center, blockTopY: self.blockStartRule.isHidden ? nil : self.blockStartRule.frame.minY)
        }
    }

    private static func summary(for text: String) -> String {
        let line = text
            .components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .first(where: { !$0.isEmpty }) ?? "terminal block"
        let limit = 38
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}

extension GhosttySurfaceScrollView {
    nonisolated static func linkHoverURL(from link: ghostty_action_mouse_over_link_s) -> String? {
        guard link.len > 0, let bytes = link.url else { return nil }
        return String(data: Data(bytes: bytes, count: Int(link.len)), encoding: .utf8)
    }

    func setLinkHoverURL(_ url: String?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.setLinkHoverURL(url) }
            return
        }
        linkHoverIndicatorView.setURL(url)
    }

    func installSemanticHoverCopy(surfaceView: GhosttyNSView) {
        let overlay = TerminalSemanticHoverCopyView(surfaceView: surfaceView)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

extension TerminalPanelView {
    var completionRootDirectory: String? {
        let directory = panel.directory.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return directory.isEmpty ? nil : directory
    }
}

func shouldAllowEnsureFocusWindowActivation(
    activeTabManager: TabManager?,
    targetTabManager: TabManager,
    keyWindow: NSWindow?,
    mainWindow: NSWindow?,
    targetWindow: NSWindow
) -> Bool {
    guard activeTabManager === targetTabManager || (keyWindow == nil && mainWindow == nil) else {
        return false
    }

    if let keyWindow {
        return keyWindow === targetWindow
    }

    if let mainWindow {
        return mainWindow === targetWindow
    }

    return true
}

extension TerminalSurface {
    func debugInitialCommand() -> String? {
        initialCommand
    }

    func debugTmuxStartCommand() -> String? {
        tmuxStartCommand
    }

    func debugInitialInputMetadata() -> (hasInitialInput: Bool, byteCount: Int) {
        let byteCount = initialInput?.utf8.count ?? 0
        return (byteCount > 0, byteCount)
    }

    func debugInitialInputForTesting() -> String? {
        initialInput
    }
}
