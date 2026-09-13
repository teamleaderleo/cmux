import AppKit
import Testing
@testable import CmuxSwiftRenderUI

@MainActor
@Suite struct DirectHoverTests {
    @Test func pointerMovementRestoresHoverWithoutReenteringRow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let view = DirectHoverView(frame: NSRect(x: 0, y: 0, width: 180, height: 30))
        try #require(window.contentView).addSubview(view)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved,
            location: NSPoint(x: 20, y: 15), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        view.mouseMoved(with: event)
        #expect(view.hovered)
    }
}
