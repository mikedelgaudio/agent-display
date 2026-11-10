import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit

enum Capture {
    /// Screenshot a whole display (default: the agent display) or one app's window.
    /// Uses ScreenCaptureKit, so it works on a virtual display nobody is looking at.
    static func screenshot(_ a: Args, defaultMaxDim: Int?) async throws -> Output {
        guard CGPreflightScreenCaptureAccess() else {
            throw ToolError("Screen Recording permission missing for the process running agent-display. Run `agent-display permissions --prompt`, then enable it in System Settings > Privacy & Security > Screen & System Audio Recording.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        var meta: [String: Any] = [:]

        if let appArg = a.str("app") {
            let app = try resolveApp(appArg)
            var wins = content.windows.filter { $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 1 }
            if let t = a.str("title")?.lowercased() { wins = wins.filter { ($0.title ?? "").lowercased().contains(t) } }
            guard let w = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                throw ToolError("no on-screen window for \(app.localizedName ?? appArg)")
            }
            filter = SCContentFilter(desktopIndependentWindow: w)
            meta["window"] = ["title": w.title ?? "", "frame": rectDict(w.frame), "windowID": Int(w.windowID)]
        } else {
            let id = try resolveDisplay(a.str("display") ?? "Agent Display")
            guard let d = content.displays.first(where: { $0.displayID == id }) else { throw ToolError("display \(id) not capturable") }
            filter = SCContentFilter(display: d, excludingWindows: [])
            meta["displayID"] = Int(id)
            meta["frame"] = rectDict(CGDisplayBounds(id))
        }

        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)
        var pw = rect.width * scale, ph = rect.height * scale
        if let maxDim = a.int("max-dim") ?? defaultMaxDim, maxDim > 0, max(pw, ph) > CGFloat(maxDim) {
            let f = CGFloat(maxDim) / max(pw, ph)
            pw *= f; ph *= f
        }
        let config = SCStreamConfiguration()
        config.width = Int(pw.rounded())
        config.height = Int(ph.rounded())
        config.showsCursor = false
        config.scalesToFit = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        meta["imageWidth"] = image.width
        meta["imageHeight"] = image.height
        // Multiply image pixel coordinates by this to get points for `click`.
        meta["pointsPerPixel"] = Double(rect.width) / Double(image.width)

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolError("PNG encoder unavailable")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("PNG encoding failed") }
        return .image(png: data as Data, meta: meta)
    }
}
