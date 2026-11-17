import AppKit
import Observation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAsLoginItem = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        setupStatusItem()

        let firstRun = !model.config.hasCompletedSetup
        let afterUpdate = CommandLine.arguments.contains("--updated")
        model.start(afterUpdate: afterUpdate)
        trackModel()

        if firstRun || model.config.showWindowAtLaunch || !(launchedAsLoginItem || afterUpdate) {
            showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where model.handle(url: url) {
            showMainWindow()
        }
    }

    // MARK: - Menu bar icon

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let hosting = NSHostingController(rootView: MenuBarView(
            openWindow: { [weak self] in self?.showMainWindow() },
            quit: { NSApp.terminate(nil) }
        ).environment(model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        updateStatusIcon()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbol = "display.2"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: model.isSwitching ? .bold : .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Monitor Switcher")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !model.config.automationEnabled
        let auto = model.config.automationEnabled ? "automatic" : "automatic switching paused"
        button.toolTip = "Monitor Switcher — monitors on the \(model.mode.title) (\(auto))"
    }

    private func trackModel() {
        withObservationTracking {
            _ = model.mode
            _ = model.isSwitching
            _ = model.config.automationEnabled
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusIcon()
                self?.trackModel()
            }
        }
    }

    // MARK: - Main window

    func showMainWindow() {
        popover.performClose(nil)
        if window == nil {
            let hosting = NSHostingController(rootView: MainView().environment(model))
            hosting.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.contentViewController = hosting
            window.title = "Monitor Switcher"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = NSSize(width: 800, height: 560)
            window.setContentSize(NSSize(width: 920, height: 640))
            window.center()
            window.setFrameAutosaveName("MainWindow")
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // The app keeps running in the menu bar; drop the Dock icon.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Monitor Switcher", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Monitor Switcher", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Monitor Switcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
