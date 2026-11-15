import AppKit
import ScreenCaptureKit

/// Window snapshots through ScreenCaptureKit. Needs Screen Recording access; without it nothing is captured.
enum Thumbnailer {
    /// Snapshots of the windows among `windows` that are on a Space, including other Spaces, each fitting `maxSize` points at `scale` pixels per point.
    static func capture(_ windows: [WindowInfo], maxSize: CGSize, scale: CGFloat) async -> [CGWindowID: CGImage] {
        let ids = Set(windows.filter(\.isOnSpace).map(\.id))
        guard !ids.isEmpty, CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return [:] }
        let targets = content.windows.filter { ids.contains($0.windowID) && $0.frame.width > 0 && $0.frame.height > 0 }
        return await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for window in targets {
                group.addTask {
                    let fit = min(maxSize.width / window.frame.width, maxSize.height / window.frame.height, 1)
                    let config = SCStreamConfiguration()
                    config.width = max(1, Int(window.frame.width * fit * scale))
                    config.height = max(1, Int(window.frame.height * fit * scale))
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return (window.windowID, image)
                }
            }
            var images: [CGWindowID: CGImage] = [:]
            for await (id, image) in group {
                if let image { images[id] = image }
            }
            return images
        }
    }
}
