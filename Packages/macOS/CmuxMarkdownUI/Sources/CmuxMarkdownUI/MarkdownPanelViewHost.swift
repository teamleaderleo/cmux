public import AppKit
public import Combine
public import SwiftUI

/// The display mode rendered by the Markdown panel composition.
public enum MarkdownPanelDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case preview
    case text

    public var id: Self { self }
}

/// The values and actions the Markdown panel composition reads from its host.
public protocol MarkdownPanelViewHost: ObservableObject {
    var filePath: String { get }
    var displayIcon: String? { get }
    var content: String { get }
    var markdownDisplayMode: MarkdownPanelDisplayMode { get }
    var isFileUnavailable: Bool { get }
    var isDirty: Bool { get }
    var isSaving: Bool { get }
    var focusFlashToken: Int { get }
    var fontSize: Double { get }
    var fontFamily: String { get }
    var maxContentWidth: Double { get }
    var hasSearchState: Bool { get }

    func updateDisplayMode(_ mode: MarkdownPanelDisplayMode)
    func loadText()
    func saveText()
    func reload()
    func setFontSize(_ value: Double) -> Bool
    func setFontFamily(_ value: String) -> Bool
    func setMaxContentWidth(_ value: Double) -> Bool
    func resetTypography()
    func resetTypographyToBuiltInDefaults()
    func copyMarkdown()
    func copyHTML()
}

/// Appearance values needed by the package-owned Markdown composition.
public struct MarkdownPanelAppearance: Sendable {
    public let backgroundColor: NSColor
    public let contentBackgroundColor: NSColor
    public let foregroundColor: NSColor
    public let colorScheme: ColorScheme
    public let drawsContentBackground: Bool

    public init(
        backgroundColor: NSColor,
        contentBackgroundColor: NSColor,
        foregroundColor: NSColor,
        colorScheme: ColorScheme,
        drawsContentBackground: Bool
    ) {
        self.backgroundColor = backgroundColor
        self.contentBackgroundColor = contentBackgroundColor
        self.foregroundColor = foregroundColor
        self.colorScheme = colorScheme
        self.drawsContentBackground = drawsContentBackground
    }
}

/// App-owned renderers and chrome used by the package-owned composition.
public struct MarkdownPanelViewAdapters<Model: MarkdownPanelViewHost> {
    public let preview: (_ model: Model, _ appearance: MarkdownPanelAppearance, _ visible: Bool, _ portalPriority: Int) -> AnyView
    public let textEditor: (_ model: Model, _ appearance: MarkdownPanelAppearance, _ visible: Bool, _ wordWrap: Bool) -> AnyView
    public let searchOverlay: (_ model: Model) -> AnyView
    public let fileHeader: (_ model: Model, _ appearance: MarkdownPanelAppearance, _ content: AnyView) -> AnyView
    public let focusFlash: (_ opacity: Double) -> AnyView

    public init(
        preview: @escaping (_ model: Model, _ appearance: MarkdownPanelAppearance, _ visible: Bool, _ portalPriority: Int) -> AnyView,
        textEditor: @escaping (_ model: Model, _ appearance: MarkdownPanelAppearance, _ visible: Bool, _ wordWrap: Bool) -> AnyView,
        searchOverlay: @escaping (_ model: Model) -> AnyView,
        fileHeader: @escaping (_ model: Model, _ appearance: MarkdownPanelAppearance, _ content: AnyView) -> AnyView,
        focusFlash: @escaping (_ opacity: Double) -> AnyView
    ) {
        self.preview = preview
        self.textEditor = textEditor
        self.searchOverlay = searchOverlay
        self.fileHeader = fileHeader
        self.focusFlash = focusFlash
    }
}

/// Renders Markdown panel state while leaving app-specific WebKit and panel state in the host.
@MainActor
public struct MarkdownPanelView<Model: MarkdownPanelViewHost>: View {
    @ObservedObject private var model: Model
    private let isFocused: Bool
    private let portalPriority: Int
    private let isVisibleInUI: Bool
    private let appearance: MarkdownPanelAppearance
    private let adapters: MarkdownPanelViewAdapters<Model>
    private let onRequestPanelFocus: () -> Void
    @AppStorage(FilePreviewWordWrapSettings.key) private var fileEditorWordWrap = FilePreviewWordWrapSettings.defaultEnabled
    @State private var focusFlashOpacity = 0.0
    @State private var copyConfirmation: String?
    @State private var copyConfirmationGeneration = 0

    public init(
        model: Model,
        isFocused: Bool,
        isVisibleInUI: Bool,
        portalPriority: Int,
        appearance: MarkdownPanelAppearance,
        adapters: MarkdownPanelViewAdapters<Model>,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        self._model = ObservedObject(wrappedValue: model)
        self.isFocused = isFocused
        self.isVisibleInUI = isVisibleInUI
        self.portalPriority = portalPriority
        self.appearance = appearance
        self.adapters = adapters
        self.onRequestPanelFocus = onRequestPanelFocus
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            adapters.fileHeader(model, appearance, AnyView(toolbar))
            Divider()
            if model.isFileUnavailable {
                unavailableView
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .overlay { adapters.focusFlash(focusFlashOpacity) }
        .onChange(of: model.focusFlashToken) { triggerFocusFlash() }
        .environment(\.colorScheme, appearance.colorScheme)
    }

    @ViewBuilder private var content: some View {
        ZStack {
            adapters.preview(model, appearance, isVisibleInUI, portalPriority)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(model.markdownDisplayMode == .preview ? 1 : 0)
                .allowsHitTesting(model.markdownDisplayMode == .preview)
                .accessibilityHidden(model.markdownDisplayMode != .preview)
            if model.markdownDisplayMode == .text {
                adapters.textEditor(model, appearance, isVisibleInUI, fileEditorWordWrap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.markdownDisplayMode == .preview, model.hasSearchState {
                adapters.searchOverlay(model)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if model.markdownDisplayMode == .text {
                headerButton("arrow.counterclockwise", "Revert", disabled: !model.isDirty) { model.loadText() }
                headerButton("square.and.arrow.down", "Save", disabled: !model.isDirty || model.isSaving) { model.saveText() }
            } else {
                headerButton("arrow.clockwise", "Refresh") { model.reload() }
            }
            headerButton(model.markdownDisplayMode == .preview ? "doc.plaintext" : "eye", model.markdownDisplayMode == .preview ? "Show TextEdit" : "Show Preview") {
                model.updateDisplayMode(model.markdownDisplayMode == .preview ? .text : .preview)
            }
            headerButton("doc.on.doc", copyConfirmation ?? "Copy as Markdown") {
                model.copyMarkdown(); flashCopyConfirmation("Copied as Markdown")
            }
            headerButton("chevron.left.forwardslash.chevron.right", "Copy as HTML") {
                model.copyHTML(); flashCopyConfirmation("Copied as HTML")
            }
        }
    }

    private func headerButton(_ systemName: String, _ label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemName).frame(width: 20, height: 20) }
            .buttonStyle(.plain).foregroundColor(.secondary).disabled(disabled)
            .help(label).accessibilityLabel(label)
    }

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark").font(.system(size: 40)).foregroundColor(.secondary)
            Text("File unavailable").font(.headline)
            Text(model.filePath).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
            Text("The file may have been moved or deleted.").font(.caption).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func triggerFocusFlash() {
        focusFlashOpacity = 1
        withAnimation(.easeOut(duration: 0.35)) { focusFlashOpacity = 0 }
    }

    private func flashCopyConfirmation(_ value: String) {
        copyConfirmationGeneration &+= 1
        let generation = copyConfirmationGeneration
        copyConfirmation = value
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard copyConfirmationGeneration == generation else { return }
            copyConfirmation = nil
        }
    }
}
