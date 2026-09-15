import CmuxSwiftRender
@testable import CmuxSwiftRenderUI
import Testing
import Foundation

@MainActor
struct SidebarJSRuntimeTests {
    @Test(arguments: [true, false])
    func acknowledgedDispatchPublishesExactOperationResult(accepted: Bool) async throws {
        let runtime = SidebarJSRuntime()
        let (events, continuation) = AsyncStream<String>.makeStream()
        defer { continuation.finish() }
        runtime.dispatch = SidebarActionDispatch(perform: { action in
            for command in action.commands {
                if case let .cmux(method, params) = command, method == "test.result" {
                    continuation.yield(params["value"] ?? "")
                }
            }
            return accepted
        })
        #expect(runtime.start(source: """
        effect(() => { const r = data.actionResult(); if (r) cmux('test.result', {value: r.operationID + ':' + r.accepted}); });
        sidebar(() => Button('Open', () => cmux('workspace.create', {operation_id:'exact-request'})));
        """))
        let button = try #require(runtime.store.rootId)
        runtime.dispatchEvent(nodeId: button, event: "tap")
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == "exact-request:\(accepted)")
    }

    /// Actions dispatch one main-queue turn after the event (paint-before-
    /// command); suspend so the queued dispatch runs before asserting.
    private func pumpActions() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test func conversationRowsHighlightAndOpenOnFirstClick() async throws {
        let runtime = SidebarJSRuntime()
        var captured: [ActionCommand] = []
        runtime.dispatch = SidebarActionDispatch { captured.append(contentsOf: $0.commands) }
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxSwiftRenderUI/Resources/ConversationSidebar.js")
        #expect(runtime.start(source: try String(contentsOf: sourceURL, encoding: .utf8)))
        runtime.updateData(key: "providerFilter", value: .string("All"))
        let history = try ConversationHistoryReader.decode(Data(#"[{"provider":"OpenCode","id":"ses_fixture","cwd":"/fixture","group":"Fixture","title":"Fixture conversation","command":"opencode --session ses_fixture","updated":1}]"#.utf8)).get()
        runtime.updateData(key: "history", value: history)
        func descendants(_ id: String) -> [String] {
            [id] + (runtime.store.node(id)?.children ?? []).flatMap { descendants($0) }
        }
        let ids = descendants(try #require(runtime.store.rootId))
        let hover = try #require(ids.compactMap { runtime.store.node($0) }.first { $0.bool("directHover") })
        #expect(hover.string("hoverBackground") != nil)
        let button = try #require(ids.first { runtime.store.node($0)?.type == "button" && runtime.store.node($0)?.string("text") == "Fixture conversation" })
        runtime.dispatchEvent(nodeId: button, event: "tap")
        runtime.dispatchEvent(nodeId: button, event: "tap")
        await pumpActions()
        #expect(captured.count == 1)
        guard case let .cmux(method, params) = try #require(captured.first) else {
            Issue.record("A chat click must open its conversation"); return
        }
        #expect(method == "workspace.create")
        #expect(params["initial_command"] == "opencode --session ses_fixture")
    }

    @Test func buildsRetainedScene() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: """
        sidebar(() => VStack({ spacing: 8 }, [
            Text("Hello").font("headline"),
            Divider(),
        ]))
        """)
        #expect(ok)
        #expect(runtime.errorMessage == nil)
        let root = runtime.store.rootId.flatMap { runtime.store.node($0) }
        #expect(root?.type == "vstack")
        #expect(root?.double("spacing") == 8)
        let first = root?.children.first.flatMap { runtime.store.node($0) }
        #expect(first?.string("text") == "Hello")
        #expect(first?.string("font") == "headline")
    }

    @Test func reactivePropUpdatesOnlyOnDataChange() {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        sidebar(() => Text(() => "count: " + (data.count() ?? 0)))
        """)
        let rootId = try! #require(runtime.store.rootId)
        #expect(runtime.store.node(rootId)?.string("text") == "count: 0")
        runtime.updateData(key: "count", value: .int(5))
        #expect(runtime.store.node(rootId)?.string("text") == "count: 5")
        // An unrelated key leaves the prop untouched.
        runtime.updateData(key: "other", value: .string("x"))
        #expect(runtime.store.node(rootId)?.string("text") == "count: 5")
    }

    @Test func keyedReconcileKeepsRowIdentityAcrossReorder() {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        sidebar(() => ForEach(
            { items: () => data.items() ?? [], key: (w) => w.id },
            (w) => Text(() => w().title)
        ))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("a"), "title": .string("A")]),
            .object(["id": .string("b"), "title": .string("B")]),
        ]))
        let before = try! #require(runtime.store.node(rootId)?.children)
        #expect(before.count == 2)

        // Reorder: identical node ids, swapped order (no remount).
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("b"), "title": .string("B")]),
            .object(["id": .string("a"), "title": .string("A")]),
        ]))
        let after = try! #require(runtime.store.node(rootId)?.children)
        #expect(after == before.reversed())

        // Removal disposes the row's nodes.
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("b"), "title": .string("B")]),
        ]))
        let remaining = try! #require(runtime.store.node(rootId)?.children)
        #expect(remaining.count == 1)
        #expect(runtime.store.node(before[0]) == nil)
    }

    @Test func rowContentUpdatesInPlace() {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        sidebar(() => ForEach(
            { items: () => data.items() ?? [], key: (w) => w.id },
            (w) => Text(() => w().title)
        ))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("a"), "title": .string("old")]),
        ]))
        let rowId = try! #require(runtime.store.node(rootId)?.children.first)
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("a"), "title": .string("new")]),
        ]))
        #expect(runtime.store.node(rootId)?.children.first == rowId)
        #expect(runtime.store.node(rowId)?.string("text") == "new")
    }

    @Test func buttonTapRunsCmuxCommand() async {
        let runtime = SidebarJSRuntime()
        var captured: [ActionCommand] = []
        runtime.dispatch = SidebarActionDispatch { action in
            captured.append(contentsOf: action.commands)
        }
        runtime.start(source: """
        sidebar(() => Button("Select", () => cmux("workspace.select", { workspace_id: "w1" })))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.dispatchEvent(nodeId: rootId, event: "tap")
        await pumpActions()
        #expect(captured == [.cmux(method: "workspace.select", params: ["workspace_id": "w1"])])
    }

    @Test func reorderableCarriesItemKeysAndMoveHandler() async {
        let runtime = SidebarJSRuntime()
        var captured: [ActionCommand] = []
        runtime.dispatch = SidebarActionDispatch { action in
            captured.append(contentsOf: action.commands)
        }
        runtime.start(source: """
        sidebar(() => Reorderable(
            {
                items: () => data.items() ?? [],
                key: (w) => w.id,
                onMove: (id, index) => cmux("workspace.reorder", { workspace_id: id, index: index }),
            },
            (w) => Text(() => w().title)
        ))
        """)
        let rootId = try! #require(runtime.store.rootId)
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("a"), "title": .string("A")]),
            .object(["id": .string("b"), "title": .string("B")]),
        ]))
        #expect(runtime.store.node(rootId)?.string("itemKeys") == #"["a","b"]"#)
        runtime.dispatchEvent(nodeId: rootId, event: "move", payload: ["id": "a", "index": 1])
        await pumpActions()
        #expect(captured == [.cmux(method: "workspace.reorder", params: ["workspace_id": "a", "index": "1"])])
    }

    @Test func contextMenuAttachesAsMenuChild() async {
        let runtime = SidebarJSRuntime()
        var captured: [ActionCommand] = []
        runtime.dispatch = SidebarActionDispatch { action in
            captured.append(contentsOf: action.commands)
        }
        runtime.start(source: """
        sidebar(() =>
          Text("row").contextMenu([
            Button("Pin", () => cmux("workspace.action", { action: "pin", workspace_id: "w1" })),
            Divider(),
            Menu("Move", [Button("Up", () => cmux("workspace.action", { action: "move_up" }))]),
          ])
        )
        """)
        let rootId = try! #require(runtime.store.rootId)
        let root = try! #require(runtime.store.node(rootId))
        #expect(root.type == "text")
        let menuId = try! #require(root.children.first)
        let menu = try! #require(runtime.store.node(menuId))
        #expect(menu.type == "contextMenu")
        #expect(menu.children.count == 3)
        // Menu item taps dispatch like any button.
        runtime.dispatchEvent(nodeId: menu.children[0], event: "tap")
        await pumpActions()
        #expect(captured == [.cmux(method: "workspace.action", params: ["action": "pin", "workspace_id": "w1"])])
        // Submenu node carries its title and item.
        let submenu = try! #require(runtime.store.node(menu.children[2]))
        #expect(submenu.type == "menu")
        #expect(submenu.string("text") == "Move")
    }

    @Test func textFieldEditEventFiresLive() {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        const [q, setQ] = signal("");
        sidebar(() => VStack({}, [
            TextField("", { autofocus: false, onEdit: (t) => setQ(t) }),
            Text(() => "q:" + q()),
        ]))
        """)
        let rootId = try! #require(runtime.store.rootId)
        let root = try! #require(runtime.store.node(rootId))
        let fieldId = try! #require(root.children.first)
        let labelId = try! #require(root.children.dropFirst().first)
        #expect(runtime.store.node(fieldId)?.props["autofocus"] == .bool(false))
        runtime.dispatchEvent(nodeId: fieldId, event: "edit", payload: ["text": "se"])
        #expect(runtime.store.node(labelId)?.string("text") == "q:se")
        runtime.dispatchEvent(nodeId: fieldId, event: "edit", payload: ["text": "sess"])
        #expect(runtime.store.node(labelId)?.string("text") == "q:sess")
    }

    @Test func authorSignalsDriveBindings() {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        const [open, setOpen] = signal(false);
        sidebar(() => Text(() => (open() ? "open" : "closed")).onTap(() => setOpen(!open())))
        """)
        let rootId = try! #require(runtime.store.rootId)
        #expect(runtime.store.node(rootId)?.string("text") == "closed")
        runtime.dispatchEvent(nodeId: rootId, event: "tap")
        #expect(runtime.store.node(rootId)?.string("text") == "open")
    }

    @Test func numericPropsWithValueOneStayNumeric() {
        // Regression: NSNumber(1) bridges to Bool via `as?`, which turned
        // lineLimit(1)/opacity(1) into booleans and silently dropped them.
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        sidebar(() => Text("t").lineLimit(1).opacity(1).padding(0).rotation(90).fade(30).marquee())
        """)
        let rootId = try! #require(runtime.store.rootId)
        let node = try! #require(runtime.store.node(rootId))
        #expect(node.props["lineLimit"] == .number(1))
        #expect(node.props["opacity"] == .number(1))
        #expect(node.props["padding"] == .number(0))
        #expect(node.props["rotation"] == .number(90))
        #expect(node.props["fade"] == .number(30))
        // Bare `.marquee()` defaults to true (delay comes from the host).
        #expect(node.props["marquee"] == .bool(true))
        // Booleans still decode as booleans.
        #expect(node.props["tappable"] == nil)
    }

    @Test func programErrorSurfacesWithLine() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: "sidebar(() => notAFunction())")
        #expect(!ok)
        #expect(runtime.errorMessage?.contains("line") == true)
    }

    @Test func missingRootIsAnError() {
        let runtime = SidebarJSRuntime()
        let ok = runtime.start(source: "const x = 1")
        #expect(!ok)
        #expect(runtime.errorMessage != nil)
    }

    @Test func validateAcceptsGoodProgramAndRejectsBadOne() {
        #expect(SidebarJSRuntime.validate(
            source: "sidebar(() => Text(\"ok\"))",
            state: CustomSidebarValidator.defaultDataContext
        ) == nil)
        #expect(SidebarJSRuntime.validate(
            source: "sidebar(() => missing())",
            state: [:]
        ) != nil)
    }

    @Test func watchdogTerminatesRunawayProgram() {
        // The hard limit resolves a non-public JSC symbol; skip when absent
        // (the test would otherwise hang forever).
        guard JSWatchdog.install(on: JSContextHolder.make(), seconds: 0.05) else { return }
        let message = SidebarJSRuntime.validate(source: "while (true) {}", state: [:])
        #expect(message != nil)
    }
}

import JavaScriptCore

enum JSContextHolder {
    static func make() -> JSContext { JSContext()! }
}
