import SwiftUI
import Foundation
import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxTestSupport
import CmuxTerminal
import CmuxFoundation
import CmuxSettings
import UniformTypeIdentifiers

/// View for rendering a terminal panel
struct TerminalPanelView: View {
    @ObservedObject var panel: TerminalPanel
    @AppStorage(NotificationPaneRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    @AppStorage(TerminalTextBoxInputSettings.maxLinesKey)
    private var textBoxMaxLines = TerminalTextBoxInputSettings.defaultMaxLines
    @AppStorage(SessionContentWidthSettings.maxWidthKey)
    private var storedSessionContentMaximumWidth = SessionContentWidthSettings.noMaximumWidth
    @AppStorage(SessionContentWidthSettings.alignmentKey)
    private var storedSessionContentAlignment = SessionContentAlignment.center.rawValue
    @State private var terminalFontSize = GhosttyConfig.load(globalFontMagnificationPercent: GlobalFontMagnification.storedPercent).fontSize
    @State private var clipboardPreview: TerminalClipboardPreview?
    @State private var clipboardPreviewChangeCount = -1
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    var portalPaneOwnershipResolver: (@MainActor () -> Bool)? = nil
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let terminalAgentContext: String
    let onFocus: () -> Void
    let onResumeAgentHibernation: () -> Void
    let onAutoResumeAgentHibernation: () -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        switch panel.agentHibernationPhase {
        case .live:
            terminalBody
        case .terminating:
            Color(nsColor: appearance.contentBackgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id("hibernation-terminating-\(panel.id.uuidString)")
        case .recovering(let hibernationState):
            AgentHibernationPlaceholderView(
                state: hibernationState,
                appearance: appearance,
                mode: AgentHibernationPlaceholderMode.recovering,
                onAction: nil
            )
            .id("hibernation-termination-recovery-\(panel.id.uuidString)")
        case .terminationFailed(let hibernationState):
            AgentHibernationPlaceholderView(
                state: hibernationState,
                appearance: appearance,
                mode: AgentHibernationPlaceholderMode.failed,
                onAction: {
                    panel.retryAgentHibernationTermination()
                }
            )
            .id("hibernation-termination-failed-\(panel.id.uuidString)")
        case .hibernated(let hibernationState):
            hibernationBody(hibernationState)
        }
    }

    @ViewBuilder
    private func hibernationBody(_ hibernationState: AgentHibernationPanelState) -> some View {
        if isVisibleInUI {
            Color(nsColor: appearance.contentBackgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id("hibernated-resuming-\(panel.id.uuidString)")
                .onAppear {
                    onAutoResumeAgentHibernation()
                }
        } else {
            AgentHibernationPlaceholderView(
                state: hibernationState,
                appearance: appearance,
                mode: AgentHibernationPlaceholderMode.hibernated,
                onAction: onResumeAgentHibernation
            )
            .id("hibernated-\(panel.id.uuidString)")
            .onChange(of: isVisibleInUI) { _, visible in
                if visible {
                    onAutoResumeAgentHibernation()
                }
            }
        }
    }

    private var terminalBody: some View {
        @Bindable var textBoxState = panel.textBoxState

        return VStack(spacing: 0) {
            // Layering contract: terminal find UI is mounted in GhosttySurfaceScrollView (AppKit portal layer)
            // via `searchState`. Rendering `SurfaceSearchOverlay` in this SwiftUI container can hide it.
            GhosttyTerminalView(
                terminalSurface: panel.surface,
                paneId: paneId,
                isActive: isFocused,
                isVisibleInUI: isVisibleInUI,
                ownershipGeneration: panel.portalHostOwnershipGeneration,
                isCurrentPaneOwner: currentPortalPaneOwner,
                portalZPriority: portalPriority,
                showsInactiveOverlay: isSplit && !isFocused,
                showsUnreadNotificationRing: hasUnreadNotification && notificationPaneRingEnabled,
                inactiveOverlayColor: appearance.unfocusedOverlayNSColor,
                inactiveOverlayOpacity: appearance.unfocusedOverlayOpacity,
                searchState: panel.searchState,
                reattachToken: panel.viewReattachToken,
                sessionContentWidthPresentation: sessionContentWidthPresentation,
                onFocus: { _ in
                    panel.terminalDidBecomeFocused()
                    onFocus()
                },
                onTriggerFlash: onTriggerFlash
            )
            // Keep the NSViewRepresentable identity stable across bonsplit structural updates.
            // This prevents transient teardown/recreate that can momentarily detach the hosted terminal view.
            .id(panel.id)
            .background(Color.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#if DEBUG
            .reportTerminalViewportGeometryForUITest(panel: panel)
#endif
            .layoutPriority(1)

            if panel.isTextBoxActive {
                TextBoxInputContainer(
                    text: $panel.textBoxContent,
                    attachments: $panel.textBoxAttachments,
                    selectedSubmitActionID: $textBoxState.selectedSubmitActionID,
                    pendingProviderLaunchAction: $textBoxState.pendingProviderLaunchAction,
                    pendingProviderLaunchStartedAt: $textBoxState.pendingProviderLaunchStartedAt,
                    surface: panel.surface,
                    terminalBackgroundColor: appearance.backgroundColor,
                    terminalForegroundColor: appearance.foregroundColor,
                    terminalFont: NSFont.monospacedSystemFont(
                        ofSize: terminalFontSize,
                        weight: .regular
                    ),
                    maxLines: TerminalTextBoxInputSettings.resolvedMaxLines(textBoxMaxLines),
                    terminalAgentContext: effectiveTerminalAgentContext,
                    shellActivityState: panel.shellActivity.state,
                    allowsCommandTemplateSubmit: TextBoxInputContainer.allowsCommandTemplateSubmit(
                        shellActivityState: panel.shellActivity.state
                    ),
                    onFocusTextBox: {
                        panel.textBoxDidBecomeFocused()
                        onFocus()
                    },
                    onToggleFocus: {
                        _ = panel.focusTextBoxInputOrTerminal()
                    },
                    onSelectSubmitAction: { actionID in
                        panel.textBoxState.selectSubmitAction(actionID)
                    },
                    onRecordLaunchCommand: { command in
                        panel.recordTextBoxLaunchCommand(command)
                    },
                    onClearLaunchCommand: {
                        panel.clearTextBoxLaunchCommand()
                    },
                    onEscape: {
                        panel.handleTextBoxEscape()
                    },
                    onTextViewCreated: { view in
                        panel.registerTextBoxInputView(view)
                    },
                    onTextViewMovedToWindow: { view in
                        panel.textBoxInputViewDidMoveToWindow(view)
                    },
                    onTextViewDismantled: { view in
                        panel.preserveTextBoxContentForUnmount(from: view)
                    }
                )
                .sessionContentWidth(fillsHeight: false)
                .overlay(alignment: .bottomLeading) {
                    if shouldWatchClipboardPreview,
                       let clipboardPreview {
                        TerminalClipboardPreviewOverlay(
                            preview: clipboardPreview,
                            foregroundColor: appearance.foregroundColor
                        )
                        .id(clipboardPreviewChangeCount)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: clipboardPreviewChangeCount)
                .task(id: shouldWatchClipboardPreview) {
                    if shouldWatchClipboardPreview {
                        await watchClipboardPreview()
                    } else {
                        clipboardPreview = nil
                    }
                }
            }
        }
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            terminalFontSize = GhosttyConfig.load(globalFontMagnificationPercent: GlobalFontMagnification.storedPercent).fontSize
        }
    }

    private var shouldWatchClipboardPreview: Bool {
        isVisibleInUI
            && panel.isTextBoxActive
            && panel.textBoxContent.isEmpty
            && panel.textBoxAttachments.isEmpty
    }

    @MainActor
    private func watchClipboardPreview() async {
        clipboardPreviewChangeCount = -1
        refreshClipboardPreviewIfNeeded()

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: NSApp.isActive ? 120_000_000 : 450_000_000)
            } catch {
                break
            }
            guard !Task.isCancelled else { break }
            refreshClipboardPreviewIfNeeded()
        }
    }

    @MainActor
    private func refreshClipboardPreviewIfNeeded() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != clipboardPreviewChangeCount else { return }
        clipboardPreviewChangeCount = changeCount
        clipboardPreview = TerminalClipboardPreview.read(from: pasteboard)
    }

    private var sessionContentWidthPresentation: SessionContentWidthPresentation {
        SessionContentWidthPresentation(
            storedMaximumWidth: storedSessionContentMaximumWidth,
            storedAlignment: storedSessionContentAlignment
        )
    }

    @MainActor
    private func currentPortalPaneOwner() -> Bool {
        if let portalPaneOwnershipResolver {
            return portalPaneOwnershipResolver()
        }
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == panel.workspaceId }),
              let livePanel = workspace.panels[panel.id],
              livePanel === panel,
              let currentPane = workspace.paneId(forPanelId: panel.id),
              currentPane.id == paneId.id,
              let tabId = workspace.surfaceIdFromPanelId(panel.id) else {
            return false
        }
        return workspace.bonsplitController.selectedTab(inPane: currentPane)?.id == tabId
    }

    private var effectiveTerminalAgentContext: String {
        Self.effectiveTerminalAgentContext(
            terminalAgentContext,
            pendingLaunchCommand: panel.textBoxState.pendingLaunchCommand
        )
    }

    static func effectiveTerminalAgentContext(
        _ terminalAgentContext: String,
        pendingLaunchCommand: String?
    ) -> String {
        var context = terminalAgentContext
        appendTextBoxLaunchContext(
            "textBoxPendingLaunchCommand:",
            command: pendingLaunchCommand,
            to: &context
        )
        return context
    }

    private static func appendTextBoxLaunchContext(
        _ prefix: String,
        command: String?,
        to context: inout String
    ) {
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return }
        let marker = "\(prefix)\(command)"
        let existingLines = context
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !existingLines.contains(marker) else { return }
        if context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context = marker
        } else {
            context += "\n\(marker)"
        }
    }
}

private struct TerminalClipboardPreview: Equatable {
    let label: String

    @MainActor
    static func read(from pasteboard: NSPasteboard) -> TerminalClipboardPreview? {
        let types = pasteboard.types ?? []

        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            if urls.count == 1 {
                let name = urls[0].lastPathComponent.isEmpty ? urls[0].path : urls[0].lastPathComponent
                return TerminalClipboardPreview(label: "Clipboard · \(name)")
            }
            return TerminalClipboardPreview(label: "Clipboard · \(urls.count) files")
        }

        if types.contains(where: isImageType) {
            return TerminalClipboardPreview(label: "Clipboard · Image")
        }

        if let rawText = GhosttyApp.terminalPasteboard.fallbackPlainTextContents(from: pasteboard) {
            let collapsed = rawText
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !collapsed.isEmpty else { return nil }
            let limit = 84
            let excerpt = collapsed.count > limit
                ? String(collapsed.prefix(limit - 1)) + "…"
                : collapsed
            return TerminalClipboardPreview(label: "Clipboard · “\(excerpt)”")
        }

        return nil
    }

    private static func isImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
        if type == .tiff || type == .png { return true }
        guard let utType = UTType(type.rawValue) else { return false }
        return utType.conforms(to: .image)
    }
}

private struct TerminalClipboardPreviewOverlay: View {
    let preview: TerminalClipboardPreview
    let foregroundColor: NSColor

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 45)

            Text(preview.label)
                .cmuxFont(size: 14)
                .foregroundStyle(Color(nsColor: foregroundColor).opacity(0.42))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
                .padding(.horizontal, 1)
                .background(.regularMaterial)

            Color.clear
                .frame(width: 45)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AgentHibernationPlaceholderView: View {
    let state: AgentHibernationPanelState
    let appearance: PanelAppearance
    let mode: AgentHibernationPlaceholderMode
    let onAction: (() -> Void)?

    private var title: String {
        switch mode {
        case .hibernated:
            String(
                localized: "terminal.agentHibernation.title",
                defaultValue: "Agent hibernated"
            )
        case .recovering:
            String(
                localized: "terminal.agentHibernation.finishing",
                defaultValue: "Finishing agent shutdown"
            )
        case .failed:
            String(
                localized: "terminal.agentHibernation.failed",
                defaultValue: "Agent shutdown needs attention"
            )
        }
    }

    private var actionTitle: String? {
        switch mode {
        case .hibernated:
            String(localized: "terminal.agentHibernation.resume", defaultValue: "Resume")
        case .recovering:
            nil
        case .failed:
            String(
                localized: "terminal.agentHibernation.retry",
                defaultValue: "Retry shutdown"
            )
        }
    }

    private var lastActivityText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: state.lastActivityAt, relativeTo: Date())
    }

    var body: some View {
        VStack(spacing: 14) {
            switch mode {
            case .recovering:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("AgentHibernationTerminationRecoveryProgress")
            case .hibernated:
                CmuxSystemSymbolImage(magnified: "pause.circle", pointSize: 34, weight: .regular)
                    .foregroundStyle(.secondary)
            case .failed:
                CmuxSystemSymbolImage(
                    magnified: "exclamationmark.triangle",
                    pointSize: 34,
                    weight: .regular
                )
                .foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                Text(title)
                    .cmuxFont(.headline)
                Text(state.agentDisplayName)
                    .cmuxFont(.subheadline)
                    .foregroundStyle(.secondary)
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "terminal.agentHibernation.lastActivity", defaultValue: "Last activity %@"),
                        lastActivityText
                    )
                )
                .cmuxFont(.caption)
                .foregroundStyle(.tertiary)
            }
            if let actionTitle, let onAction {
                Button(actionTitle) {
                    onAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(
                    mode == .failed
                        ? "AgentHibernationTerminationRetryButton"
                        : "AgentHibernationResumeButton"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }
}

#if DEBUG
private extension View {
    func reportTerminalViewportGeometryForUITest(panel: TerminalPanel) -> some View {
        modifier(TerminalViewportGeometryReporter(panel: panel))
    }
}

private struct TerminalViewportGeometryReporter: ViewModifier {
    @ObservedObject var panel: TerminalPanel

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        recordTerminalViewportGeometryForUITest(proxy: proxy, panel: panel)
                    }
                    .onChange(of: proxy.size) {
                        recordTerminalViewportGeometryForUITest(proxy: proxy, panel: panel)
                    }
            }
        }
    }
}

@MainActor
private func recordTerminalViewportGeometryForUITest(proxy: GeometryProxy, panel: TerminalPanel) {
    let env = ProcessInfo.processInfo.environment
    guard env["CMUX_UI_TEST_TERMINAL_VIEWPORT_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        return
    }

    let hostedView = panel.hostedView
    let hostedFrame = hostedView.frame
    let hostedBounds = hostedView.bounds
    let hostedSuperviewBounds = hostedView.superview?.bounds ?? .zero
    let windowContentBounds = hostedView.window?.contentView?.bounds ?? .zero
    let hostedFrameInContent: NSRect
    if let contentView = hostedView.window?.contentView {
        hostedFrameInContent = contentView.convert(hostedView.convert(hostedView.bounds, to: nil), from: nil)
    } else {
        hostedFrameInContent = .zero
    }

    _ = UITestCaptureSink().mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_TERMINAL_VIEWPORT_PATH") { payload in
        payload["terminalViewportPanelId"] = panel.id.uuidString
        payload["terminalViewportPanelWidth"] = terminalViewportFormat(proxy.size.width)
        payload["terminalViewportPanelHeight"] = terminalViewportFormat(proxy.size.height)
        payload["terminalViewportHostedFrameMinX"] = terminalViewportFormat(hostedFrame.minX)
        payload["terminalViewportHostedFrameMinY"] = terminalViewportFormat(hostedFrame.minY)
        payload["terminalViewportHostedFrameMaxX"] = terminalViewportFormat(hostedFrame.maxX)
        payload["terminalViewportHostedFrameMaxY"] = terminalViewportFormat(hostedFrame.maxY)
        payload["terminalViewportHostedFrameWidth"] = terminalViewportFormat(hostedFrame.width)
        payload["terminalViewportHostedFrameHeight"] = terminalViewportFormat(hostedFrame.height)
        payload["terminalViewportHostedBoundsWidth"] = terminalViewportFormat(hostedBounds.width)
        payload["terminalViewportHostedBoundsHeight"] = terminalViewportFormat(hostedBounds.height)
        payload["terminalViewportHostedSuperviewWidth"] = terminalViewportFormat(hostedSuperviewBounds.width)
        payload["terminalViewportHostedSuperviewHeight"] = terminalViewportFormat(hostedSuperviewBounds.height)
        payload["terminalViewportWindowContentWidth"] = terminalViewportFormat(windowContentBounds.width)
        payload["terminalViewportWindowContentHeight"] = terminalViewportFormat(windowContentBounds.height)
        payload["terminalViewportHostedContentMinX"] = terminalViewportFormat(hostedFrameInContent.minX)
        payload["terminalViewportHostedContentMinY"] = terminalViewportFormat(hostedFrameInContent.minY)
        payload["terminalViewportHostedContentMaxX"] = terminalViewportFormat(hostedFrameInContent.maxX)
        payload["terminalViewportHostedContentMaxY"] = terminalViewportFormat(hostedFrameInContent.maxY)
    }
}

private func terminalViewportFormat(_ value: CGFloat) -> String {
    String(format: "%.3f", Double(value))
}
#endif

/// Shared appearance settings for panels
struct PanelAppearance {
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let dividerColor: Color
    let unfocusedOverlayNSColor: NSColor
    let unfocusedOverlayOpacity: Double
    let usesClearContentBackground: Bool
    init(
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        dividerColor: Color,
        unfocusedOverlayNSColor: NSColor,
        unfocusedOverlayOpacity: Double,
        usesClearContentBackground: Bool
    ) {
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.dividerColor = dividerColor
        self.unfocusedOverlayNSColor = unfocusedOverlayNSColor
        self.unfocusedOverlayOpacity = unfocusedOverlayOpacity
        self.usesClearContentBackground = usesClearContentBackground
    }

    var contentBackgroundColor: NSColor {
        usesClearContentBackground ? .clear : backgroundColor
    }

    var drawsContentBackground: Bool {
        !usesClearContentBackground
    }

    static func fromConfig(_ config: GhosttyConfig) -> PanelAppearance {
        fromConfig(
            config,
            usesTransparentWindow: WindowBackgroundComposition.policy
                .shouldUseTransparentBackgroundWindow(glassEffectAvailable: false)
        )
    }

    static func fromConfig(_ config: GhosttyConfig, usesTransparentWindow: Bool) -> PanelAppearance {
        let backgroundColor = GhosttyBackgroundTheme.color(
            backgroundColor: config.backgroundColor,
            opacity: config.backgroundOpacity
        )
        return PanelAppearance(
            backgroundColor: backgroundColor,
            foregroundColor: cmuxReadableForegroundNSColor(
                preferred: config.foregroundColor,
                on: backgroundColor
            ),
            dividerColor: Color(nsColor: config.resolvedSplitDividerColor),
            unfocusedOverlayNSColor: config.unfocusedSplitOverlayFill,
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity,
            usesClearContentBackground: shouldUseClearContentBackground(
                opacity: config.backgroundOpacity,
                usesGhosttyGlassStyle: config.backgroundBlur.isMacOSGlassStyle,
                usesTransparentWindow: usesTransparentWindow
            )
        )
    }

    static func shouldUseClearContentBackground(
        opacity: Double,
        usesGhosttyGlassStyle: Bool,
        usesTransparentWindow: Bool
    ) -> Bool {
        usesTransparentWindow || usesGhosttyGlassStyle || opacity < 0.999
    }
}
