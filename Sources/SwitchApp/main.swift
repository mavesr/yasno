import Cocoa
import SwiftUI
import SwitchCore
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var statusLabel: NSMenuItem!
    private var pauseItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.yasno.switcher")
        if let existing = others.first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        model = AppModel()
        window = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model)))
        window.title = "Ясно"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Ясно")
        let menu = NSMenu()
        statusLabel = NSMenuItem(title: model.status, action: nil, keyEquivalent: "")
        menu.addItem(statusLabel)
        menu.addItem(.separator())
        add("Открыть Ясно…", action: #selector(showWindow), to: menu)
        pauseItem = add("Приостановить", action: #selector(toggleEnabled), to: menu)
        add("Не работать в этом приложении", action: #selector(excludeApp), to: menu)
        menu.addItem(.separator())
        add("Завершить Ясно", action: #selector(quit), to: menu)
        statusItem.menu = menu
        model.onStateChange = { [weak self] in
            guard let self else { return }
            self.statusLabel.title = self.model.status
            self.pauseItem.title = self.model.enabled ? "Приостановить" : "Включить"
            self.statusItem.button?.appearsDisabled = !self.model.monitor.enabled
            self.statusItem.button?.toolTip = "Ясно — \(self.model.status)"
        }
        // The model refreshed before the menu existed; show its state now, not the defaults.
        model.onStateChange?()
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchKind = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        let backgroundLaunch = event?.eventID == kAEOpenApplication &&
            (launchKind == keyAELaunchedAsLogInItem || launchKind == keyAELaunchedAsServiceItem)
        if !backgroundLaunch || !model.accessibility || !model.inputMonitoring { showWindow() }
    }

    @discardableResult private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }
    @objc private func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func toggleEnabled() { model.enabled.toggle() }
    @objc private func excludeApp() { model.excludeFrontmost() }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}

if CommandLine.arguments.contains("--diagnose") {
    let detector = Detector()
    print("Dictionaries:", detector.counts)
    print("Accessibility:", AXIsProcessTrusted(), "Input monitoring:", CGPreflightListenEventAccess())
    for layout in KeyboardLayout.installed() { print(layout.id, layout.name, layout.languages) }
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
