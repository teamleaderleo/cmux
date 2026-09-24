import AppKit
import CmuxForeignWindows

/// Receives `claude://` GetURL Apple Events while the lab is the handler and
/// hands them to the router, which forwards each one by process id.
@MainActor
final class LabURLEventHandler: NSObject {
    private let router: ClaudeDesktopLinkRouter?

    init(router: ClaudeDesktopLinkRouter?) {
        self.router = router
    }

    func install() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURL(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        _ = replyEvent
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else {
            return
        }
        let handled = router?.route(url) ?? false
        let scheme = url.scheme ?? ""
        let host = url.host ?? ""
        FileHandle.standardError.write(
            Data("[lab] received \(scheme)://\(host)\(url.path) routed=\(handled)\n".utf8)
        )
    }
}
