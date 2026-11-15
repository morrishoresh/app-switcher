import AppKit
import ScreenCaptureKit

/// Window snapshots through ScreenCaptureKit. Needs Screen Recording access; without it nothing is captured.
enum Thumbnailer {
    /// Snapshots of the windows among `windows` that are on a Space, including other Spaces, each fitting `maxSize` points at `scale` pixels per point.
    static func capture(_ windows: [WindowInfo], maxSize: CGSize, scale: CGFloat) async -> [CGWindowID: CGImage] {
        await capture(ids: Set(windows.filter(\.isOnSpace).map(\.id)), maxSize: maxSize, scale: scale)
    }

    /// Snapshots of the windows with these IDs, which must be on a Space, each fitting `maxSize` points at `scale` pixels per point.
    static func capture(ids: Set<CGWindowID>, maxSize: CGSize, scale: CGFloat) async -> [CGWindowID: CGImage] {
        guard !ids.isEmpty, CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return [:] }
        let targets = content.windows.filter { ids.contains($0.windowID) && $0.frame.width > 0 && $0.frame.height > 0 }
        var images = await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
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
        // ScreenCaptureKit cannot capture windows on a full-screen Space; SkyLight can.
        let pixels = CGSize(width: maxSize.width * scale, height: maxSize.height * scale)
        for id in ids where images[id] == nil {
            if let image = SkyLightCapture.image(of: id).flatMap({ scaled($0, toFit: pixels) }) { images[id] = image }
        }
        return images
    }

    /// SkyLight captures at full size; snapshots are kept at thumbnail size.
    private static func scaled(_ image: CGImage, toFit size: CGSize) -> CGImage? {
        let fit = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height), 1)
        let width = max(1, Int(CGFloat(image.width) * fit)), height = max(1, Int(CGFloat(image.height) * fit))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Private SkyLight window capture (as used by AltTab), resolved at run time since SkyLight has no SDK stub.
private enum SkyLightCapture {
    private typealias CaptureWindowList = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, Int32, UInt32) -> Unmanaged<CFArray>?
    private typealias MainConnectionID = @convention(c) () -> Int32
    /// Nominal resolution, ignoring the global clip shape.
    private static let options: UInt32 = 0x200 | 0x800

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let captureWindowList = dlsym(handle, "CGSHWCaptureWindowList").map { unsafeBitCast($0, to: CaptureWindowList.self) }
    private static let mainConnectionID = dlsym(handle, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnectionID.self) }

    static func image(of id: CGWindowID) -> CGImage? {
        guard let captureWindowList, let mainConnectionID else { return nil }
        var windowID = id
        let images = captureWindowList(mainConnectionID(), &windowID, 1, options)?.takeRetainedValue() as? [CGImage]
        return images?.first
    }
}
