import AppKit

/// Owns the models and resource handles scoped to a single main window.
@MainActor
final class CmuxMainWindowContext {
    let windowId: UUID
    let tabManager: TabManager
    let sidebarState: SidebarState
    let sidebarSelectionState: SidebarSelectionState
    var fileExplorerState: FileExplorerState?
    let keyboardFocusCoordinator: MainWindowFocusController
    var cmuxConfigStore: CmuxConfigStore?
    var closeObserver: WindowCloseObserver?
    weak var window: NSWindow?
    /// Per-window Dock owned by this context and torn down with it.
    var windowDock: DockSplitStore?
    private let workspaceTerminalFontSizeArbiter:
        WorkspaceTerminalFontSizeArbiter
    /// Window-scoped font-size queue. Requests contain stable workspace ids;
    /// teardown cancels the queue before any surface owner is released.
    lazy var workspaceTerminalFontSizeCoordinator =
        WorkspaceTerminalFontSizeCoordinator(
            tabManager: tabManager,
            arbiter: workspaceTerminalFontSizeArbiter
        )
#if DEBUG
    var debugWorkspaceTerminalFontSizeEnqueueResultOverride: Bool?
#endif

    init(
        windowId: UUID,
        tabManager: TabManager,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState,
        fileExplorerState: FileExplorerState?,
        cmuxConfigStore: CmuxConfigStore?,
        window: NSWindow?,
        workspaceTerminalFontSizeArbiter:
            WorkspaceTerminalFontSizeArbiter
    ) {
        self.windowId = windowId
        self.tabManager = tabManager
        self.sidebarState = sidebarState
        self.sidebarSelectionState = sidebarSelectionState
        self.fileExplorerState = fileExplorerState
        self.cmuxConfigStore = cmuxConfigStore
        self.window = window
        self.workspaceTerminalFontSizeArbiter =
            workspaceTerminalFontSizeArbiter
        self.keyboardFocusCoordinator = MainWindowFocusController(
            windowId: windowId,
            window: window,
            tabManager: tabManager,
            fileExplorerState: fileExplorerState
        )
    }
}
