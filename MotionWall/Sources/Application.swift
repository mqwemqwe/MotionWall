import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = AppModel()
    private var panel: NSWindow?
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu()
        menu.delegate = self
        add("Открыть MotionWall…", action: #selector(showPanel), to: menu)
        add("Выбрать видео…", action: #selector(chooseMovie), to: menu)
        menu.addItem(.separator())
        pauseItem = add("Пауза", action: #selector(togglePause), to: menu)
        add("Убрать обои", action: #selector(removeWallpaper), to: menu)
        menu.addItem(.separator())
        add("Завершить MotionWall", action: #selector(quit), to: menu, key: "q")
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "MotionWall")
        status.button?.toolTip = "MotionWall — живые обои"
        status.menu = menu
        statusItem = status
        let mainMenu = NSMenu()
        let appMenu = NSMenuItem()
        appMenu.submenu = NSMenu()
        add("Завершить MotionWall", action: #selector(quit), to: appMenu.submenu!, key: "q")
        mainMenu.addItem(appMenu)
        NSApp.mainMenu = mainMenu
        model.start()
        // A login launch with active wallpaper remains unobtrusive. Opening the app again shows the panel.
        if !model.preferences.enabled || CommandLine.arguments.contains("--show") { showPanel() }
        else { model.setPreviewVisible(false) }
    }

    @discardableResult private func add(_ title: String, action: Selector, to menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }
    func menuWillOpen(_ menu: NSMenu) {
        pauseItem?.title = model.preferences.paused ? "Продолжить" : "Пауза"
        pauseItem?.isEnabled = model.preferences.enabled
    }
    @objc func showPanel() {
        if panel == nil {
            let availableHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 70
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: min(810, availableHeight)),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "MotionWall"
            window.contentView = NSHostingView(rootView: ScrollView { MainView(model: model) })
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            panel = window
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        model.setPreviewVisible(true)
    }
    @objc func chooseMovie() { showPanel(); model.chooseMovie() }
    @objc func togglePause() { model.togglePause() }
    @objc func removeWallpaper() { model.removeWallpaper() }
    @objc func quit() { NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) { model.setPreviewVisible(false) }
    func windowDidMiniaturize(_ notification: Notification) { model.setPreviewVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { model.setPreviewVisible(true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}

@main
enum MotionWall {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
