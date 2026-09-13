import AppKit
import SwiftUI

/// Requests another bounded batch when the user approaches the end of history.
struct ConversationScrollDemand: NSViewRepresentable {
    var identity: String = ""
    let loadMore: @MainActor () -> Void

    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {
        view.loadMore = loadMore
        if view.identity != identity {
            view.identity = identity
            view.requested = false
        }
    }

    final class Observer: NSView {
        var identity = ""
        var requested = false
        var loadMore: (@MainActor () -> Void)?
        private weak var clip: NSClipView?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in self?.attach() }
        }
        private func attach() {
            NotificationCenter.default.removeObserver(self)
            clip = enclosingScrollView?.contentView
            guard let clip else { return }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification, object: clip)
        }
        @objc private func boundsChanged() {
            guard let clip, let document = clip.documentView, window != nil else { return }
            let remaining = document.bounds.height - clip.bounds.maxY
            if remaining > 240 { requested = false }
            guard remaining < 160, !requested else { return }
            requested = true
            let expectedIdentity = identity
            // Bounds notifications can arrive during layout. Publish after that
            // transaction, once per threshold crossing, never from view body.
            Task { @MainActor [weak self] in
                guard let self, self.window != nil, self.identity == expectedIdentity else { return }
                self.loadMore?()
            }
        }
    }
}
