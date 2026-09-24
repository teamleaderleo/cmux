import AppKit
import CmuxForeignWindows
import Foundation
import SwiftUI

struct ClaudeDesktopAgentSurface: View {
    let panelID: UUID
    let profile: String
    let isFocused: Bool
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    var onRequestPanelFocus: () -> Void = {}

    var body: some View {
        ForeignWindowSurface(
            panelID: panelID,
            profile: profile,
            registry: ClaudeDesktopAppRuntime.hosting.registry,
            accessibility: ClaudeDesktopAppRuntime.hosting.accessibility,
            isFocused: isFocused,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }
}
