import AppKit
import SwiftUI

@main
enum AIUsageBarMain {
    private static var retainedDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let store = UsageStore()

    // Menu-bar apps must NOT quit when the menu content (the only UI surface) is
    // dismissed. Default AppKit behavior can silently terminate us otherwise.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            StatusItemVisuals.configure(button)
        }

        let usageItem = NSMenuItem()
        let host = NSHostingView(rootView: ContentView().environmentObject(store))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 500)
        usageItem.view = host
        menu = StatusMenuBuilder.makeMenu(
            usageItem: usageItem,
            quitTarget: NSApp,
            quitAction: #selector(NSApplication.terminate(_:))
        )
        menu.delegate = self
        statusItem.menu = menu

        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in await store.refresh(allowingCredentialPrompts: true) }
    }
}
