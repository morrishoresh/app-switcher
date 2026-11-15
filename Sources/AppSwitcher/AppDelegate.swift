import AppKit
import Carbon.HIToolbox
import ServiceManagement
import os

let log = Logger(subsystem: "com.morrishoresh.AppSwitcher", category: "app")

/// One option of a menu-bar setting: picking it stores `value` under `key` and applies it.
private final class SettingChoice: NSObject {
    let key: String
    let value: Double
    let apply: (Double) -> Void

    init(key: String, value: Double, apply: @escaping (Double) -> Void) {
        self.key = key
        self.value = value
        self.apply = apply
    }
}

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
    private static let switcherPreviewsKey = "switcherPreviews"
    private static let eachWindowKey = "switcherEachWindow"
    private let eachWindowItem = NSMenuItem(title: "Show Each Window Separately", action: #selector(toggleEachWindow), keyEquivalent: "")
    private static let switcherPreviewWidthKey = "switcherPreviewWidth"
    private static let switcherOthersScaleKey = "switcherOthersScale"
    private static let dockPreviewWidthKey = "dockPreviewWidth"
    private static let appsPerRowKey = "switcherAppsPerRow"
    /// Before blur was per desktop: on or off everywhere.
    private static let legacyBlurKey = "blurBackground"
    /// UUIDs of the desktops with Blur Background Apps on.
    private static let blurSpacesKey = "blurSpaces"
    private static let switcherBlurKey = "switcherBlurApps"
    private static let blurGrayscaleKey = "blurGrayscale"
    private let grayscaleItem = NSMenuItem(title: "Grayscale", action: #selector(toggleGrayscale), keyEquivalent: "")
    private static let blurDesktopKey = "blurDesktop"
    private let blurDesktopItem = NSMenuItem(title: "Blur Desktop", action: #selector(toggleBlurDesktop), keyEquivalent: "")
    private let switcherBlurItem = NSMenuItem(title: "Blur All Apps", action: #selector(toggleSwitcherBlur), keyEquivalent: "")
    private static let blurRadiusKey = "blurRadius"
    private let blur = BackgroundBlur()
    private let blurItem = NSMenuItem(title: "Blur Background Apps on This Desktop", action: #selector(toggleBlur), keyEquivalent: "b")
    /// ⌘B anywhere turns the blur on and off.
    private var blurHotKey: HotKey?
    /// While the menu is open, its own key equivalent handles ⌘B.
    private var isMenuOpen = false
    /// Width to height of preview snapshots.
    private static let previewAspect = 0.625
    private var choiceItems: [NSMenuItem] = []
    private let switcherPreviewsItem = NSMenuItem(title: "Show Window Previews", action: #selector(toggleSwitcherPreviews), keyEquivalent: "")
    private let dockPreviewsItem = NSMenuItem(title: "Dock Previews", action: #selector(toggleDockPreviews), keyEquivalent: "")
    private let screenRecordingItem = NSMenuItem(title: "Open Screen Recording Settings…", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
    private let showWindowlessItem = NSMenuItem(title: "Show Apps Without Windows", action: #selector(toggleShowWindowless), keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "⌘⇥ Switcher", action: #selector(toggleEnabled), keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true, Self.showWindowlessKey: false, Self.dockPreviewsKey: true,
                                                  Self.switcherPreviewsKey: false, Self.switcherPreviewWidthKey: 320.0,
                                                  Self.switcherOthersScaleKey: 0.6, Self.dockPreviewWidthKey: 220.0,
                                                  Self.appsPerRowKey: 0.0, Self.eachWindowKey: true,
                                                  Self.blurRadiusKey: 20.0,
                                                  Self.switcherBlurKey: true, Self.blurGrayscaleKey: false,
                                                  Self.blurDesktopKey: false])
        controller.showsAppsWithoutWindows = UserDefaults.standard.bool(forKey: Self.showWindowlessKey)
        controller.showsPreviews = UserDefaults.standard.bool(forKey: Self.switcherPreviewsKey)
        controller.showsEachWindow = UserDefaults.standard.bool(forKey: Self.eachWindowKey)
        blur.radius = UserDefaults.standard.double(forKey: Self.blurRadiusKey)
        controller.blur.radius = blur.radius
        controller.blursApps = UserDefaults.standard.bool(forKey: Self.switcherBlurKey)
        blur.isGrayscale = UserDefaults.standard.bool(forKey: Self.blurGrayscaleKey)
        controller.blur.isGrayscale = blur.isGrayscale
        blur.blursDesktop = UserDefaults.standard.bool(forKey: Self.blurDesktopKey)
        controller.blur.blursDesktop = blur.blursDesktop
        if UserDefaults.standard.object(forKey: Self.blurSpacesKey) == nil {
            // Blur that was on everywhere is turned on for each existing desktop.
            let wasOn = UserDefaults.standard.bool(forKey: Self.legacyBlurKey)
            UserDefaults.standard.set(wasOn ? WindowScanner.allSpaces() : [], forKey: Self.blurSpacesKey)
            UserDefaults.standard.removeObject(forKey: Self.legacyBlurKey)
        }
        blur.enabledSpaces = Set(UserDefaults.standard.stringArray(forKey: Self.blurSpacesKey) ?? [])
        blurHotKey = HotKey(keyCode: kVK_ANSI_B, modifiers: cmdKey) { [weak self] in
            guard let self, !self.isMenuOpen else { return }
            self.toggleBlur()
        }
        dockPreview.isEnabled = UserDefaults.standard.bool(forKey: Self.dockPreviewsKey)
        if dockPreview.isEnabled || controller.showsPreviews { requestScreenRecording() }
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
        switcherPreviewsItem.target = self
        eachWindowItem.target = self
        eachWindowItem.indentationLevel = 1
        blurItem.target = self
        switcherBlurItem.target = self
        grayscaleItem.target = self
        grayscaleItem.indentationLevel = 1
        blurDesktopItem.target = self
        blurDesktopItem.indentationLevel = 1
        switcherBlurItem.indentationLevel = 1
        dockPreviewsItem.target = self
        screenRecordingItem.target = self
        // Each feature is turned on and off on its own, with its settings indented below it.
        statusLine.indentationLevel = 1
        showWindowlessItem.indentationLevel = 1
        switcherPreviewsItem.indentationLevel = 1
        menu.addItem(enabledItem)
        menu.addItem(statusLine)
        menu.addItem(eachWindowItem)
        menu.addItem(showWindowlessItem)
        menu.addItem(switcherBlurItem)
        menu.addItem(switcherPreviewsItem)
        menu.addItem(settingMenu("Selected Preview Size", key: Self.switcherPreviewWidthKey,
                                 options: [("Small", 240), ("Medium", 320), ("Large", 400), ("Extra Large", 480)]) {
            SwitcherPanel.previewSize = CGSize(width: $0, height: $0 * Self.previewAspect)
        })
        menu.addItem(settingMenu("Other Previews Size", key: Self.switcherOthersScaleKey,
                                 options: [("40% of Selected", 0.4), ("60% of Selected", 0.6), ("80% of Selected", 0.8),
                                           ("Same as Selected", 1)]) {
            SwitcherPanel.previewScale = $0
        })
        menu.addItem(settingMenu("Apps per Row", key: Self.appsPerRowKey,
                                 options: [("As Many as Fit", 0), ("5", 5), ("8", 8), ("10", 10), ("12", 12), ("16", 16)]) {
            SwitcherPanel.appsPerRow = Int($0)
        })
        menu.addItem(.separator())
        menu.addItem(dockPreviewsItem)
        menu.addItem(settingMenu("Preview Size", key: Self.dockPreviewWidthKey,
                                 options: [("Small", 160), ("Medium", 220), ("Large", 300), ("Extra Large", 380)]) {
            DockPreviewPanel.thumbnailSize = CGSize(width: $0, height: ($0 * Self.previewAspect).rounded())
        })
        menu.addItem(.separator())
        menu.addItem(blurItem)
        menu.addItem(blurSliderItem())
        menu.addItem(grayscaleItem)
        menu.addItem(blurDesktopItem)
        menu.addItem(.separator())
        menu.addItem(accessibilityItem)
        menu.addItem(screenRecordingItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AppSwitcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateStatusIcon()
    }

    /// An indented submenu choosing one value for `key`; applies the stored value now.
    private func settingMenu(_ title: String, key: String, options: [(String, Double)],
                             apply: @escaping (Double) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.indentationLevel = 1
        let submenu = NSMenu()
        for (name, value) in options {
            let choice = NSMenuItem(title: name, action: #selector(chooseSetting(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = SettingChoice(key: key, value: value, apply: apply)
            submenu.addItem(choice)
            choiceItems.append(choice)
        }
        item.submenu = submenu
        apply(UserDefaults.standard.double(forKey: key))
        return item
    }

    /// Slider for the blur amount, indented under Blur Background Apps; also sets the ⌘⇥ blur. Changes apply while dragging.
    private func blurSliderItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        let slider = NSSlider(value: blur.radius, minValue: BackgroundBlur.radiusRange.lowerBound,
                              maxValue: BackgroundBlur.radiusRange.upperBound, target: self, action: #selector(blurRadiusChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 36, y: 3, width: view.frame.width - 36 - 16, height: 20)
        slider.autoresizingMask = [.width]
        view.autoresizingMask = [.width]
        view.addSubview(slider)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    @objc private func blurRadiusChanged(_ sender: NSSlider) {
        blur.radius = sender.doubleValue
        controller.blur.radius = sender.doubleValue
        UserDefaults.standard.set(sender.doubleValue, forKey: Self.blurRadiusKey)
    }

    @objc private func toggleBlurDesktop() {
        blur.blursDesktop.toggle()
        controller.blur.blursDesktop = blur.blursDesktop
        UserDefaults.standard.set(blur.blursDesktop, forKey: Self.blurDesktopKey)
    }

    @objc private func toggleGrayscale() {
        blur.isGrayscale.toggle()
        controller.blur.isGrayscale = blur.isGrayscale
        UserDefaults.standard.set(blur.isGrayscale, forKey: Self.blurGrayscaleKey)
    }

    @objc private func toggleSwitcherBlur() {
        controller.blursApps.toggle()
        UserDefaults.standard.set(controller.blursApps, forKey: Self.switcherBlurKey)
    }

    /// Turns Blur Background Apps on or off for the current desktop.
    @objc private func toggleBlur() {
        guard let space = WindowScanner.activeSpace() else { return }
        if blur.enabledSpaces.contains(space) { blur.enabledSpaces.remove(space) } else { blur.enabledSpaces.insert(space) }
        // Desktops that no longer exist are dropped.
        let existing = Set(WindowScanner.allSpaces())
        UserDefaults.standard.set(blur.enabledSpaces.filter(existing.contains).sorted(), forKey: Self.blurSpacesKey)
    }

    @objc private func chooseSetting(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SettingChoice else { return }
        UserDefaults.standard.set(choice.value, forKey: choice.key)
        choice.apply(choice.value)
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

    @objc private func toggleEachWindow() {
        controller.showsEachWindow.toggle()
        UserDefaults.standard.set(controller.showsEachWindow, forKey: Self.eachWindowKey)
    }

    @objc private func toggleSwitcherPreviews() {
        controller.showsPreviews.toggle()
        UserDefaults.standard.set(controller.showsPreviews, forKey: Self.switcherPreviewsKey)
        if controller.showsPreviews { requestScreenRecording() }
    }

    @objc private func toggleDockPreviews() {
        dockPreview.isEnabled.toggle()
        UserDefaults.standard.set(dockPreview.isEnabled, forKey: Self.dockPreviewsKey)
        log.info("Dock previews: \(self.dockPreview.isEnabled)")
        if dockPreview.isEnabled { requestScreenRecording() }
        updateStatusIcon()
    }

    /// Window snapshots need Screen Recording access; without it previews show app icons in their place.
    /// macOS asks only the first time; later the menu links to the setting.
    private func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    @objc private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }
    func menuDidClose(_ menu: NSMenu) { isMenuOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        showWindowlessItem.state = controller.showsAppsWithoutWindows ? .on : .off
        switcherPreviewsItem.state = controller.showsPreviews ? .on : .off
        eachWindowItem.state = controller.showsEachWindow ? .on : .off
        blurItem.state = WindowScanner.activeSpace().map(blur.enabledSpaces.contains) == true ? .on : .off
        switcherBlurItem.state = controller.blursApps ? .on : .off
        grayscaleItem.state = blur.isGrayscale ? .on : .off
        blurDesktopItem.state = blur.blursDesktop ? .on : .off
        for item in choiceItems {
            guard let choice = item.representedObject as? SettingChoice else { continue }
            item.state = UserDefaults.standard.double(forKey: choice.key) == choice.value ? .on : .off
        }
        dockPreviewsItem.state = dockPreview.isEnabled ? .on : .off
        screenRecordingItem.isHidden = !(dockPreview.isEnabled || controller.showsPreviews) || CGPreflightScreenCaptureAccess()
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
