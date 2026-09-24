public import AppKit
public import SwiftUI

/// SwiftUI wrapper around ``ForeignWindowHostView``.
///
/// Dismantling the view only detaches its lease; the panel's close path ends
/// the process through ``ForeignWindowProfileRegistry/releasePanel(_:)``.
public struct ForeignWindowSurface: NSViewRepresentable {
    let panelID: UUID
    let profile: String
    let registry: ForeignWindowProfileRegistry
    let accessibility: ForeignWindowAccessibility
    let isFocused: Bool
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let onRequestPanelFocus: () -> Void

    /// Creates a surface for one pane.
    ///
    /// - Parameter panelID: The panel that claims `profile` in `registry`.
    /// - Parameter profile: The profile whose window this pane shows.
    /// - Parameter registry: The registry the host view leases from.
    /// - Parameter accessibility: The trust gate the sessions use.
    /// - Parameter isFocused: Whether the pane has focus.
    /// - Parameter isVisibleInUI: Whether the pane is on screen.
    /// - Parameter backgroundColor: Fill shown behind placeholders.
    /// - Parameter onRequestPanelFocus: Focuses this pane on placeholder click.
    public init(
        panelID: UUID,
        profile: String,
        registry: ForeignWindowProfileRegistry,
        accessibility: ForeignWindowAccessibility,
        isFocused: Bool,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        self.panelID = panelID
        self.profile = profile
        self.registry = registry
        self.accessibility = accessibility
        self.isFocused = isFocused
        self.isVisibleInUI = isVisibleInUI
        self.backgroundColor = backgroundColor
        self.onRequestPanelFocus = onRequestPanelFocus
    }

    public func makeNSView(context: Context) -> ForeignWindowHostView {
        ForeignWindowHostView(
            panelID: panelID,
            profile: profile,
            registry: registry,
            accessibility: accessibility
        )
    }

    public func updateNSView(
        _ nsView: ForeignWindowHostView,
        context: Context
    ) {
        _ = context
        nsView.onRequestPanelFocus = onRequestPanelFocus
        nsView.update(
            isFocused: isFocused,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor
        )
    }

    public static func dismantleNSView(
        _ nsView: ForeignWindowHostView,
        coordinator: ()
    ) {
        _ = coordinator
        // Detach only; the panel's close path ends the process.
        nsView.detach()
    }
}
