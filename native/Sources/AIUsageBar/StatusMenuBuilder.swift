import AppKit

enum StatusMenuBuilder {
    static func makeMenu(
        usageItem: NSMenuItem,
        quitTarget: AnyObject?,
        quitAction: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(usageItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit AIUsageBar",
            action: quitAction,
            keyEquivalent: "q"
        )
        quitItem.target = quitTarget
        menu.addItem(quitItem)

        return menu
    }
}
