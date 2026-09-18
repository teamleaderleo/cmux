import AppKit
import SwiftUI
import CmuxSwiftRender

/// Visual-only title reveal: no per-frame sidebar state or JavaScript evaluation.
struct NativeMarquee: NSViewRepresentable {
    let node: SceneNode
    func makeNSView(context: Context) -> NativeMarqueeView { NativeMarqueeView() }
    func updateNSView(_ view: NativeMarqueeView, context: Context) {
        view.configure(text: node.string("text") ?? "", size: node.double("font") ?? 13,
                       delay: node.double("nativeMarquee") ?? 0.04)
    }
}

final class NativeMarqueeView: NSView {
    private static weak var active: NativeMarqueeView?
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var pending: DispatchWorkItem?
    private var hovered = false
    private var delay = 0.04
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        label.wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 17) }
    func configure(text: String, size: Double, delay: Double) {
        let font = NSFont.systemFont(ofSize: size, weight: .regular)
        if label.stringValue != text || label.font != font { stop(); label.stringValue = text; label.font = font }
        self.delay = max(0, delay)
        needsLayout = true
    }
    override func layout() { super.layout(); stop(); label.frame = bounds }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        guard NSApp.currentEvent?.type != .scrollWheel,
              window.map({ visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) }) == true else { return }
        guard !hovered else { return }
        Self.active?.hovered = false
        Self.active?.stop()
        Self.active = self
        hovered = true
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reveal() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    override func mouseMoved(with event: NSEvent) { mouseEntered(with: event) }
    override func mouseExited(with event: NSEvent) { hovered = false; stop() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrollPositionChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }
    @objc private func scrollPositionChanged() { hovered = false; stop() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hovered = false; stop() }
        super.viewWillMove(toWindow: newWindow)
    }
    private func stop() {
        pending?.cancel(); pending = nil
        label.layer?.removeAllAnimations()
        label.frame = bounds
    }
    private func reveal() {
        guard hovered, Self.active === self, window?.isKeyWindow == true,
              visibleRect.contains(convert(window!.mouseLocationOutsideOfEventStream, from: nil)),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let width = ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 13)]).width) + 4
        let overflow = width - bounds.width
        guard overflow > 1 else { return }
        label.frame.size.width = width
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = -overflow
        animation.duration = max(1, overflow / 25)
        animation.autoreverses = false
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        label.layer?.add(animation, forKey: "title-reveal")
    }
}
