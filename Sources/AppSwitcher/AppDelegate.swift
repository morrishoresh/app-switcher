import AppKit
import ServiceManagement
import os

let log = Logger(subsystem: "com.morrishoresh.AppSwitcher", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let tracker = AppTracker()
    private lazy var controller = SwitcherController(tracker: tracker)
    private lazy var eventTap = EventTap(controller: controller)
    private let dockPreview = DockPreviewController()
    private var statusItem: NSStatusItem!
    private var retryTimer: Timer?
    private static let enabledKey = "enabled"
    private static let showWindowlessKey = "showAppsWithoutWindows"
    private static let dockPreviewsKey = "dockPreviews"
    private let dockPreviewsItem = NSMenuItem(title: "Dock Previews", action: #selector(toggleDockPreviews), keyEquivalent: "")
    private let screenRecordingItem = NSMenuItem(title: "Open Screen Recording Settings…", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
    private let showWindowlessItem = NSMenuItem(title: "Show Apps Without Windows", action: #selector(toggleShowWindowless), keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "⌘⇥ Switcher", action: #selector(toggleEnabled), keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true, Self.showWindowlessKey: false, Self.dockPreviewsKey: true])
        controller.showsAppsWithoutWindows = UserDefaults.standard.bool(forKey: Self.showWindowlessKey)
        dockPreview.isEnabled = UserDefaults.standard.bool(forKey: Self.dockPreviewsKey)
        if dockPreview.isEnabled { requestScreenRecording() }
        eventTap.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        tracker.start()
        setUpStatusItem()
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        log.info("Accessibility trusted: \(trusted)")
        startEventTap()
    }

    /// The tap can only be created once Accessibility access is granted, so keep retrying until then.
    private func startEventTap() {
        if eventTap.start() {
            retryTimer?.invalidate()
            retryTimer = nil
            log.info("Event tap installed")
            dockPreview.accessibilityDidBecomeAvailable()
            return
        }
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.startEventTap()
        }
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "AppSwitcher")
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        accessibilityItem.target = self
        loginItem.target = self
        enabledItem.target = self
        showWindowlessItem.target = self
        dockPreviewsItem.target = self
        screenRecordingItem.target = self
        // Each feature is turned on and off on its own, with its settings indented below it.
        statusLine.indentationLevel = 1
        showWindowlessItem.indentationLevel = 1
        screenRecordingItem.indentationLevel = 1
        menu.addItem(enabledItem)
        menu.addItem(statusLine)
        menu.addItem(showWindowlessItem)
        menu.addItem(.separator())
        menu.addItem(dockPreviewsItem)
        menu.addItem(screenRecordingItem)
        menu.addItem(.separator())
        menu.addItem(accessibilityItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AppSwitcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        statusItem.button?.appearsDisabled = !eventTap.isEnabled && !dockPreview.isEnabled
    }

    @objc private func toggleEnabled() {
        eventTap.isEnabled.toggle()
        UserDefaults.standard.set(eventTap.isEnabled, forKey: Self.enabledKey)
        log.info("Enabled: \(self.eventTap.isEnabled)")
        updateStatusIcon()
    }

    @objc private func toggleShowWindowless() {
        controller.showsAppsWithoutWindows.toggle()
        UserDefaults.standard.set(controller.showsAppsWithoutWindows, forKey: Self.showWindowlessKey)
    }

    @objc private func toggleDockPreviews() {
        dockPreview.isEnabled.toggle()
        UserDefaults.standard.set(dockPreview.isEnabled, forKey: Self.dockPreviewsKey)
        log.info("Dock previews: \(self.dockPreview.isEnabled)")
        if dockPreview.isEnabled { requestScreenRecording() }
        updateStatusIcon()
    }

    /// Window snapshots need Screen Recording access; without it previews show titles and tabs only.
    /// macOS asks only the first time; later the menu links to the setting.
    private func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    @objc private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        showWindowlessItem.state = controller.showsAppsWithoutWindows ? .on : .off
        dockPreviewsItem.state = dockPreview.isEnabled ? .on : .off
        screenRecordingItem.isHidden = !dockPreview.isEnabled || CGPreflightScreenCaptureAccess()
        let installed = eventTap.isInstalled
        enabledItem.state = eventTap.isEnabled ? .on : .off
        statusLine.title = !installed ? "Waiting for Accessibility access"
            : eventTap.isEnabled ? "Handling ⌘⇥" : "⌘⇥ opens the built-in switcher"
        accessibilityItem.isHidden = installed
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log.error("Launch at login toggle failed: \(error.localizedDescription)")
            NSAlert(error: error).runModal()
        }
    }
}
