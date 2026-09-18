import AppKit
import SwiftUI
import CmuxSwiftRender

public struct ConversationSidebarView: View {
    private let hostContext: [String: SwiftValue]
    private let live: Bool
    @State private var historyStore = ConversationHistoryStore.shared
    @State private var ownerWindowID: String?
    @State private var ownerWindowNumber: Int?
    public init(dataContext: [String: SwiftValue] = [:], dispatch: SidebarActionDispatch, live: Bool = true) {
        self.hostContext = dataContext; self.dispatch = dispatch; self.live = live
    }
    let dispatch: SidebarActionDispatch
    @State private var showOpenTabs = true
    @State private var visibleCount = 24
    @State private var visibleIdentity = "Codex:"
    @State private var providerFilter = "Codex"
    @State private var providerMenuVisible = false
    @State private var headingHovered = false
    @State private var commandHeld = false
    @State private var pinJump = 0
    @State private var jumpSerial = 0
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var searchHovered = false
    @FocusState private var searchFocused: Bool
    @State private var searchVisible = false
    @State private var searchQuery = ""
    @State private var lastProvider = "Codex"
    private let providers = ["Claude", "Codex", "OpenCode"]
    private var newProvider: String { providerFilter == "All" ? lastProvider : providerFilter }
    private func newDraft(_ provider: String) {
        lastProvider = provider
        let selectedID = hostContext["selectedId"]?.displayString
        let selected = hostContext["workspaces"]?.iterationValues?.first { $0.member("id")?.displayString == selectedID }
        let directory = selected?.member("directory")?.displayString ?? NSHomeDirectory()
        let command = provider == "Claude" ? "claude" : provider == "OpenCode" ? "opencode" : "codex"
        scopedDispatch.run(ButtonAction(commands: [.cmux(method: "workspace.create", params: [
            "title": "New " + provider + " chat", "working_directory": directory,
            "initial_command": command, "operation_id": UUID().uuidString, "focus": "true"
        ])]))
    }
    private func dismissSearchFocus() {
        guard searchVisible else { return }
        searchFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        if searchQuery.isEmpty { searchVisible = false }
    }
    private var scopedDispatch: SidebarActionDispatch {
        let sink = dispatch
        let identifier = ownerWindowID
        let attached = ownerWindowNumber != nil
        if let perform = sink.perform {
            return SidebarActionDispatch(perform: { action in
                guard attached else { return false }
                return await perform(ConversationWindowRouting.scope(action, identifier: identifier))
            })
        }
        return SidebarActionDispatch { action in
            guard attached else { return }
            sink.run(ConversationWindowRouting.scope(action, identifier: identifier))
        }
    }
    private var replaySource: String { Self.program }
    private static let program = (try? String(contentsOf: Bundle.module.url(forResource: "ConversationSidebar", withExtension: "js")!, encoding: .utf8)) ?? ""
    private var context: [String: SwiftValue] {
        // Only send the fields this sidebar consumes. Timestamps, process
        // diagnostics and unrelated workspace metadata must not invalidate rows.
        let workspaces = (hostContext["workspaces"]?.iterationValues ?? []).map { workspace -> SwiftValue in
            var fields: [String: SwiftValue] = [:]
            for key in ["id", "title", "selected", "description"] { fields[key] = workspace.member(key) }
            fields["tabs"] = .array((workspace.member("tabs")?.iterationValues ?? []).map { tab in
                var leaf: [String: SwiftValue] = [:]
                for key in ["id", "title", "focused"] { leaf[key] = tab.member(key) }
                return .object(leaf)
            })
            fields["agents"] = .array((workspace.member("agents")?.iterationValues ?? []).map { agent in
                var leaf: [String: SwiftValue] = [:]
                for key in ["id", "kind", "panelId"] { leaf[key] = agent.member(key) }
                return .object(leaf)
            })
            return .object(fields)
        }
        var result: [String: SwiftValue] = ["workspaces": .array(workspaces)]
        result["showOpenTabs"] = .bool(showOpenTabs)
        result["history"] = historyStore.rows
        result["historyView"] = .object([
            "provider": .string(providerFilter), "query": .string(searchQuery),
            "limit": .int(visibleIdentity == providerFilter + ":" + searchQuery ? visibleCount : 24)
        ])
        result["historyLabel"] = .string(String(localized: "conversation.history", defaultValue: "History", bundle: .module))
        result["launchFailureLabel"] = .string(String(localized: "conversation.launchFailure", defaultValue: "Could not open. Click to retry.", bundle: .module))
        // Resync the retained action handler when its native window attaches.
        result["ownerWindow"] = .string((ownerWindowID ?? "") + ":" + (ownerWindowNumber.map(String.init) ?? ""))
        result["commandHeld"] = .bool(commandHeld)
        result["pinJump"] = .int(pinJump)
        result["jumpSerial"] = .int(jumpSerial)
        return result
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group {
            if searchVisible {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search conversations", text: Binding(get: { searchQuery }, set: { visibleCount = 24; searchQuery = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
                        .onAppear { searchFocused = true }
                        .onExitCommand { searchVisible = false; searchQuery = "" }
                    if !searchQuery.isEmpty {
                        Button { searchQuery = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                    Button { searchVisible = false; searchQuery = "" } label: {
                        Image(systemName: "xmark").font(.system(size: 10)).frame(width: 20, height: 24)
                    }.buttonStyle(.plain).accessibilityLabel("Close search")
                }
                .padding(9).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.15)))
                .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                .padding(.horizontal, 6).padding(.vertical, 5)

            } else {
            HStack {
                Button { providerMenuVisible.toggle() } label: {
                    HStack(spacing: 7) {
                        if providerFilter == "All" {
                            Image(systemName: "square.grid.2x2").font(.system(size: 15))
                        } else {
                            ProviderIcon(providerFilter).frame(width: 18, height: 18)
                        }
                        Text(providerFilter == "All" ? "All providers" : providerFilter)
                            .font(.system(size: 16, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(headingHovered ? Color.primary.opacity(0.09) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).fixedSize()
                    .popover(isPresented: $providerMenuVisible, arrowEdge: .bottom) {
                        QuietProviderChoices(providers: ["All"] + providers, selected: providerFilter) { provider in
                            visibleCount = 24
                            providerFilter = provider
                            providerMenuVisible = false
                        }.transaction { $0.animation = nil; $0.disablesAnimations = true }
                    }
                    .onHover { headingHovered = $0 }
                Spacer()
                Button { searchVisible.toggle(); searchFocused = searchVisible; if !searchVisible { searchQuery = "" } } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 15)).frame(width: 30, height: 30)
                        .background(searchHovered || searchVisible ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel("Search conversations").help("Search (⌘K)")
                    .onHover { searchHovered = $0 }
            }.padding(.leading, 8).padding(.trailing, 6).padding(.top, 3).padding(.bottom, 3)
            }
            }.frame(height: 40).padding(.top, 8)
            QuietNewRow(provider: newProvider, providers: providers, create: newDraft)
                .padding(.horizontal, 4).padding(.bottom, 3)
                .simultaneousGesture(TapGesture().onEnded { dismissSearchFocus() })
            HStack(spacing: 5) {
                Button { showOpenTabs.toggle() } label: {
                    Image(systemName: showOpenTabs ? "sidebar.left" : "rectangle")
                        .font(.system(size: 12)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(String(localized: "conversation.openTabs", defaultValue: "Open tabs", bundle: .module))
                    .accessibilityLabel(String(localized: "conversation.openTabs", defaultValue: "Open tabs", bundle: .module))
                Menu {
                ForEach(Array((hostContext["workspaces"]?.iterationValues ?? []).enumerated()), id: \.offset) { _, workspace in
                    if let id = workspace.member("id")?.displayString {
                        Button(workspace.member("title")?.displayString ?? id) {
                            scopedDispatch.run(ButtonAction(commands: [.cmux(method: "workspace.select", params: ["workspace_id": id])]))
                        }
                    }
                }
            } label: {
                Text(String(localized: "conversation.openNow", defaultValue: "Open now", bundle: .module))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.menuStyle(.borderlessButton).fixedSize().padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(String(localized: "conversation.switchLayout", defaultValue: "Switch between groups of open tabs", bundle: .module))
            }.padding(.leading, 8)
            if let error = historyStore.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
            }
            ScrollViewReader { scroll in
            ScrollView {
                Color.clear.frame(height: 0).id("conversation-top")
                JSSidebarHostView(
                    source: replaySource,
                    dataContext: context,
                    dispatch: scopedDispatch
                )
                .padding(4)
                .background(QuietScrollChrome())
                .background(ConversationScrollDemand(identity: providerFilter + ":" + searchQuery) {
                    let count = historyStore.rows.iterationValues?.count ?? 0
                    let identity = providerFilter + ":" + searchQuery
                    let displayed = visibleIdentity == identity ? visibleCount : 24
                    if displayed < count {
                        visibleIdentity = identity
                        visibleCount = min(count, displayed + 24)
                    }
                })
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { dismissSearchFocus() })
            .onChange(of: providerFilter) { _, _ in
                visibleIdentity = providerFilter + ":" + searchQuery
                visibleCount = 24
                scroll.scrollTo("conversation-top", anchor: .top)
            }
            .onChange(of: searchQuery) { _, _ in
                visibleIdentity = providerFilter + ":" + searchQuery
                visibleCount = 24
                scroll.scrollTo("conversation-top", anchor: .top)
            }
            }
        }
        .background(ConversationWindowReader { window in
            ownerWindowID = window?.identifier?.rawValue
            ownerWindowNumber = window?.windowNumber
        })
        .task {
            guard live else { return }
            await historyStore.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                if NSApp.isActive { await historyStore.refresh() }
            }
        }
        .onAppear {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                guard NSApp.keyWindow?.windowNumber == ownerWindowNumber && ownerWindowNumber != nil else { return event }
                commandHeld = event.modifierFlags.contains(.command)
                return event
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window?.windowNumber == ownerWindowNumber, NSApp.keyWindow?.windowNumber == ownerWindowNumber && ownerWindowNumber != nil else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags == .command && event.charactersIgnoringModifiers?.lowercased() == "k" {
                    searchVisible = true; searchFocused = true; return nil
                }
                guard flags == .command, let text = event.charactersIgnoringModifiers,
                      let number = Int(text), (1...9).contains(number) else { return event }
                pinJump = number
                jumpSerial += 1
                return nil
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            keyMonitor = nil; flagsMonitor = nil; commandHeld = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in commandHeld = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if (notification.object as? NSWindow)?.windowNumber == ownerWindowNumber { commandHeld = false }
        }
    }
}

private struct QuietNewRow: View {
    let provider: String
    let providers: [String]
    let create: (String) -> Void
    @State private var leftHovered = false
    var body: some View {
        HStack(spacing: 4) {
            Button { create(provider) } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9).frame(height: 36)
                    .contentShape(Rectangle())
                    .background(leftHovered ? Color.primary.opacity(0.09) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).frame(maxWidth: .infinity).help("New " + provider + " chat")
                .onHover { leftHovered = $0 }
            ProviderMenuButton(providers: providers.filter { $0 != provider }, create: create)
                .fixedSize(horizontal: true, vertical: false).frame(height: 36)
        }.frame(height: 36)
    }
}

private struct QuietProviderChoices: View {
    let providers: [String]
    var selected: String? = nil
    let choose: (String) -> Void
    @State private var highlighted: String? = nil
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 2) {
            ForEach(providers, id: \.self) { provider in
                Button { choose(provider) } label: {
                    HStack(spacing: 8) {
                        if provider == "All" {
                            Image(systemName: "square.grid.2x2").frame(width: 16, height: 16)
                        } else { ProviderIcon(provider).frame(width: 16, height: 16) }
                        Text(provider == "All" ? "All providers" : provider).font(.system(size: 13))
                        Spacer(minLength: 0)
                        if selected != nil {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .medium))
                                .opacity(selected == provider ? 1 : 0).frame(width: 12)
                        }
                    }.padding(.horizontal, 7).frame(height: 27)
                        .contentShape(Rectangle())
                        .background(highlighted == provider ? Color.primary.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
                    .onHover { inside in if inside { highlighted = provider } else if highlighted == provider { highlighted = nil } }
            }
        }.padding(4).frame(width: selected == nil ? 132 : 166)
            .focusable().focused($focused).focusEffectDisabled()
            .onAppear { focused = true }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.return) {
                if let provider = highlighted ?? selected ?? providers.first { choose(provider) }
                return .handled
            }
    }
    private func move(_ offset: Int) {
        guard !providers.isEmpty else { return }
        let index = highlighted.flatMap { providers.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        highlighted = providers[(index + offset + providers.count) % providers.count]
    }
}

private struct ProviderMenuButton: View {
    let providers: [String]
    let create: (String) -> Void
    @State private var visible = false
    @State private var hovered = false
    var body: some View {
        Button { visible.toggle() } label: {
            Image(systemName: "plus.circle").font(.system(size: 15))
                .foregroundStyle(.secondary).frame(width: 36, height: 36)
                .contentShape(Rectangle())
                .background(hovered ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel("New chat with another provider")
            .help("New chat with another provider")
            .popover(isPresented: $visible, arrowEdge: .bottom) {
                QuietProviderChoices(providers: providers) { provider in
                    visible = false
                    create(provider)
                }.transaction { $0.animation = nil; $0.disablesAnimations = true }
            }
    }
}

private struct QuietScrollChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ScrollChromeView() }
    func updateNSView(_ view: NSView, context: Context) {}
}
private final class QuietSidebarScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func draw(_ dirtyRect: NSRect) { drawKnob() }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        let knob = rect(for: .knob).insetBy(dx: 2, dy: 1)
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.width / 2, yRadius: knob.width / 2).fill()
    }
}

private final class ScrollChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let scroll = self?.enclosingScrollView else { return }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if !(scroll.verticalScroller is QuietSidebarScroller) {
                scroll.verticalScroller = QuietSidebarScroller()
            }
            if scroll.scrollerKnobStyle != .light { scroll.scrollerKnobStyle = .light }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ConversationWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) { view.found = found }
    final class Reader: NSView {
        var found: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.found?(self?.window) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

enum ConversationWindowRouting {
    static func scope(_ action: ButtonAction, identifier: String?) -> ButtonAction {
        guard let identifier, identifier.hasPrefix("cmux.main."),
              let id = UUID(uuidString: String(identifier.dropFirst("cmux.main.".count))) else { return action }
        return ButtonAction(commands: action.commands.map { command in
            guard case let .cmux(method, original) = command else { return command }
            var params = original
            if params["window_id"] == nil { params["window_id"] = id.uuidString }
            return .cmux(method: method, params: params)
        })
    }
}
