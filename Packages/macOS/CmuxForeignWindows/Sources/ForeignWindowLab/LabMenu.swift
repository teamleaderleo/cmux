import AppKit

/// The lab's main menu: Quit, and Lab actions routed to the window controller.
@MainActor
struct LabMenu {
    let controller: LabWindowController

    func install() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Foreign Window Lab",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let labItem = NSMenuItem()
        let labMenu = NSMenu(title: "Lab")
        let yield = labMenu.addItem(
            withTitle: "Toggle Yield",
            action: #selector(LabWindowController.toggleYield(_:)),
            keyEquivalent: "y"
        )
        yield.target = controller
        let next = labMenu.addItem(
            withTitle: "Focus Next Pane",
            action: #selector(LabWindowController.focusNextPane(_:)),
            keyEquivalent: "]"
        )
        next.target = controller
        labItem.submenu = labMenu
        mainMenu.addItem(labItem)

        NSApp.mainMenu = mainMenu
    }
}
