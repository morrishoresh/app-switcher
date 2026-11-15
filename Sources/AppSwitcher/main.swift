import AppKit
import ServiceManagement

// Command-line: AppSwitcher --launch-at-login on|off
let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--launch-at-login" {
    do {
        if arguments[2] == "on" {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        print("Launch at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
        exit(0)
    } catch {
        FileHandle.standardError.write("Failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
