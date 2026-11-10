import Foundation
import AppKit
import ApplicationServices

// MARK: - App resolution

/// Accepts a pid, bundle identifier, or app name.
func resolveApp(_ s: String) throws -> NSRunningApplication {
    if let pid = Int32(s), let app = NSRunningApplication(processIdentifier: pid) { return app }
    let apps = NSWorkspace.shared.runningApplications
    if let a = apps.first(where: { $0.bundleIdentifier?.lowercased() == s.lowercased() }) { return a }
    if let a = apps.first(where: { $0.localizedName?.lowercased() == s.lowercased() }) { return a }
    if let a = apps.first(where: { $0.executableURL?.lastPathComponent.lowercased() == s.lowercased() }) { return a }
    throw ToolError("no running app matching '\(s)' (use a pid, bundle id or name)")
}

func requireAX() throws {
    guard AXIsProcessTrusted() else {
        throw ToolError("Accessibility permission missing for the process running agent-display (your terminal or agent host). Run `agent-display permissions --prompt`, then enable it in System Settings > Privacy & Security > Accessibility.")
    }
}

func axApp(_ pid: pid_t) -> AXUIElement {
    let el = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(el, 2.0)
    return el
}

func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func axString(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = axAttr(el, name) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = axAttr(el, kAXPositionAttribute), let s = axAttr(el, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func axWindows(_ pid: pid_t) -> [AXUIElement] {
    (axAttr(axApp(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

// MARK: - Window commands

enum Apps {
    static func windows(_ a: Args) async throws -> Output {
        try requireAX()
        let app = try resolveApp(try a.req("app"))
        let wins: [[String: Any]] = axWindows(app.processIdentifier).enumerated().map { i, w in
            var d: [String: Any] = ["index": i]
            if let t = axString(w, kAXTitleAttribute) { d["title"] = t }
            if let f = axFrame(w) {
                d["frame"] = rectDict(f)
                if let disp = displayFor(point: CGPoint(x: f.midX, y: f.midY)) { d["displayID"] = Int(disp) }
            }
            if let m = axAttr(w, kAXMinimizedAttribute) as? Bool { d["minimized"] = m }
            return d
        }
        return .json(["app": app.localizedName ?? "", "pid": Int(app.processIdentifier), "windows": wins])
    }

    static func move(_ a: Args) async throws -> Output {
        try requireAX()
        let app = try resolveApp(try a.req("app"))
        let display = try resolveDisplay(a.str("display") ?? "Agent Display")
        let moved = try moveWindows(pid: app.processIdentifier, to: display, fill: a.bool("fill") ?? false, index: a.int("window"))
        return .json(["app": app.localizedName ?? "", "pid": Int(app.processIdentifier), "displayID": Int(display), "moved": moved])
    }

    @discardableResult
    static func moveWindows(pid: pid_t, to display: CGDirectDisplayID, fill: Bool, index: Int?) throws -> [[String: Any]] {
        let bounds = CGDisplayBounds(display)
        var wins = axWindows(pid)
        if let i = index {
            guard i >= 0, i < wins.count else { throw ToolError("window index \(i) out of range (\(wins.count) windows)") }
            wins = [wins[i]]
        }
        guard !wins.isEmpty else { throw ToolError("app has no windows (visible to Accessibility) yet") }
        var out: [[String: Any]] = []
        for (n, w) in wins.enumerated() {
            let cur = axFrame(w) ?? .zero
            // Leave room for the menu bar; cascade multiple windows slightly.
            var origin = CGPoint(x: bounds.minX + 20 + CGFloat(n * 24), y: bounds.minY + 40 + CGFloat(n * 24))
            var size = cur.size
            if fill {
                origin = CGPoint(x: bounds.minX, y: bounds.minY + 25)
                size = CGSize(width: bounds.width, height: bounds.height - 25)
            } else {
                size.width = min(size.width, bounds.width - 40)
                size.height = min(size.height, bounds.height - 60)
            }
            var o = origin, s = size
            if let pv = AXValueCreate(.cgPoint, &o) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
            if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv) }
            // Set position again: some apps clamp position against the old size.
            if let pv = AXValueCreate(.cgPoint, &o) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
            var d: [String: Any] = [:]
            if let t = axString(w, kAXTitleAttribute) { d["title"] = t }
            if let f = axFrame(w) { d["frame"] = rectDict(f) }
            out.append(d)
        }
        return out
    }

    /// Launch (or reuse) an app without activating it, then move its windows onto a display.
    static func launch(_ a: Args) async throws -> Output {
        try requireAX()
        let target = try a.req("app")
        let display = try resolveDisplay(a.str("display") ?? "Agent Display")

        let url: URL
        if FileManager.default.fileExists(atPath: target) {
            url = URL(fileURLWithPath: target)
        } else if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) {
            url = u
        } else if let u = NSWorkspace.shared.fullPath(forApplication: target).map({ URL(fileURLWithPath: $0) }) {
            url = u
        } else {
            throw ToolError("cannot find app '\(target)' (use a path, bundle id or app name)")
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        if let extra = a.str("args") { config.arguments = extra.split(separator: " ").map(String.init) }
        if a.bool("new-instance") == true { config.createsNewApplicationInstance = true }
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)

        let timeout = a.double("timeout") ?? 15
        let deadline = Date().addingTimeInterval(timeout)
        while axWindows(app.processIdentifier).isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let moved = (try? moveWindows(pid: app.processIdentifier, to: display, fill: a.bool("fill") ?? false, index: nil)) ?? []
        return .json([
            "app": app.localizedName ?? "", "pid": Int(app.processIdentifier),
            "bundleID": app.bundleIdentifier ?? "", "displayID": Int(display), "moved": moved,
            "note": moved.isEmpty ? "no windows appeared before timeout; run `move` once the app shows a window" : "",
        ])
    }
}
