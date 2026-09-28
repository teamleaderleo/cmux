import AppKit
import CmuxFoundation
import CmuxMarkdownUI
import SwiftUI

extension MarkdownPanel: MarkdownPanelViewHost {
    var markdownDisplayMode: CmuxMarkdownUI.MarkdownPanelDisplayMode {
        get { self.displayMode == .preview ? .preview : .text }
        set { setDisplayMode(newValue == .preview ? .preview : .text) }
    }

    var hasSearchState: Bool { searchState != nil }

    func loadText() { _ = loadTextContent(replacingDirtyContent: true) }
    func saveText() { _ = saveTextContent() }
    func reload() { _ = reloadFromDisk() }

    func copyMarkdown() {
        guard GhosttyApp.terminalPasteboard.writeString(content, to: .general) else { return }
    }

    func copyHTML() {
        Task { @MainActor in
            guard let html = await rendererSession.renderedHTML(markdown: content) else { return }
            let text = await rendererSession.renderedText() ?? content
            let item = NSPasteboardItem()
            _ = item.setString(html, forType: .html)
            _ = item.setString(text, forType: .string)
            _ = GhosttyApp.terminalPasteboard.replaceContents(of: .general, with: [item])
        }
    }
}

extension MarkdownPanel {
    @MainActor
    func cmuxMarkdownView(
        isFocused: Bool,
        isVisibleInUI: Bool,
        portalPriority: Int,
        appearance: PanelAppearance,
        onRequestPanelFocus: @escaping () -> Void
    ) -> some View {
        let packageAppearance = MarkdownPanelAppearance(
            backgroundColor: appearance.backgroundColor,
            contentBackgroundColor: appearance.contentBackgroundColor,
            foregroundColor: appearance.foregroundColor,
            colorScheme: appearance.backgroundColor.isLightColor ? .light : .dark,
            drawsContentBackground: appearance.drawsContentBackground
        )
        let adapters = MarkdownPanelViewAdapters<MarkdownPanel>(
            preview: { panel, resolvedAppearance, visible, resolvedPortalPriority in
                AnyView(MarkdownWebRenderer(
                    markdown: panel.content,
                    theme: MarkdownWebTheme.resolve(backgroundColor: resolvedAppearance.backgroundColor),
                    backgroundColor: resolvedAppearance.contentBackgroundColor,
                    isVisibleInUI: visible && panel.markdownDisplayMode == .preview,
                    portalPriority: resolvedPortalPriority,
                    panelId: panel.id,
                    workspaceId: panel.workspaceId,
                    filePath: panel.filePath,
                    fontSize: panel.fontSize,
                    fontFamily: panel.fontFamily,
                    maxContentWidth: panel.maxContentWidth,
                    session: panel.rendererSession,
                    onRequestPanelFocus: onRequestPanelFocus,
                    onViewAttachedToWindow: { [weak panel] in
                        panel?.replayPendingPreviewFocusAfterWindowAttach()
                    }
                ))
            },
            textEditor: { panel, resolvedAppearance, visible, wordWrap in
                AnyView(FilePreviewTextEditor(
                    panel: panel,
                    isVisibleInUI: visible,
                    themeBackgroundColor: resolvedAppearance.contentBackgroundColor,
                    themeForegroundColor: resolvedAppearance.foregroundColor,
                    drawsBackground: resolvedAppearance.drawsContentBackground,
                    gutterBackgroundColor: resolvedAppearance.backgroundColor,
                    wordWrap: wordWrap,
                    filePath: panel.filePath
                ))
            },
            searchOverlay: { panel in
                guard let searchState = panel.searchState else { return AnyView(EmptyView()) }
                return AnyView(BrowserSearchOverlay(
                    panelId: panel.id,
                    searchState: searchState,
                    focusRequestGeneration: panel.searchFocusRequestGeneration,
                    canApplyFocusRequest: { generation in panel.canApplySearchFocusRequest(generation) },
                    onNext: { panel.findNext() },
                    onPrevious: { panel.findPrevious() },
                    onClose: { panel.hideFind() },
                    onFieldDidFocus: {}
                ))
            },
            fileHeader: { panel, resolvedAppearance, content in
                AnyView(PanelFilePathHeader(
                    iconSystemName: panel.displayIcon ?? "doc.richtext",
                    filePath: panel.filePath,
                    foregroundColor: resolvedAppearance.foregroundColor
                ) { content })
            },
            focusFlash: { opacity in
                AnyView(WorkspaceAttentionFlashRingView(opacity: opacity))
            }
        )
        return MarkdownPanelView(
            model: self,
            isFocused: isFocused,
            isVisibleInUI: isVisibleInUI,
            portalPriority: portalPriority,
            appearance: packageAppearance,
            adapters: adapters,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }
}
