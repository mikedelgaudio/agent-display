import Foundation
import AppKit
import ApplicationServices

/// Accessibility-tree access. Pressing/setting via AX never moves the user's
/// cursor or steals keyboard focus, so it is the preferred way to drive an app.
enum AX {
    struct Node {
        let el: AXUIElement
        let path: String
        let depth: Int
    }

    static func root(_ a: Args) throws -> (NSRunningApplication, AXUIElement) {
        try requireAX()
        let app = try resolveApp(try a.req("app"))
        if let wi = a.int("window") {
            let wins = axWindows(app.processIdentifier)
            guard wi >= 0, wi < wins.count else { throw ToolError("window index \(wi) out of range (\(wins.count) windows)") }
            return (app, wins[wi])
        }
        return (app, axApp(app.processIdentifier))
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (axAttr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func walk(_ root: AXUIElement, maxDepth: Int, maxNodes: Int, _ visit: (Node) -> Bool) {
        var stack: [Node] = [Node(el: root, path: "", depth: 0)]
        var seen = 0
        while let n = stack.popLast() {
            seen += 1
            if seen > maxNodes { return }
            if !visit(n) { return }
            if n.depth >= maxDepth { continue }
            let kids = children(n.el)
            for (i, c) in kids.enumerated().reversed() {
                let p = n.path.isEmpty ? "\(i)" : "\(n.path).\(i)"
                stack.append(Node(el: c, path: p, depth: n.depth + 1))
            }
        }
    }

    static func describe(_ n: Node) -> [String: Any] {
        var d: [String: Any] = ["path": n.path.isEmpty ? "root" : n.path, "depth": n.depth]
        if let r = axString(n.el, kAXRoleAttribute) { d["role"] = r }
        if let r = axString(n.el, kAXSubroleAttribute) { d["subrole"] = r }
        if let t = axString(n.el, kAXTitleAttribute) { d["title"] = t }
        if let t = axString(n.el, kAXDescriptionAttribute) { d["description"] = t }
        if let t = axString(n.el, kAXIdentifierAttribute) { d["identifier"] = t }
        if let v = axString(n.el, kAXValueAttribute) { d["value"] = v.count > 200 ? String(v.prefix(200)) + "…" : v }
        if let e = axAttr(n.el, kAXEnabledAttribute) as? Bool, !e { d["enabled"] = false }
        if let f = axFrame(n.el) { d["frame"] = rectDict(f) }
        return d
    }

    static func tree(_ a: Args) async throws -> Output {
        let (app, root) = try root(a)
        var nodes: [[String: Any]] = []
        let interestingOnly = a.bool("all") != true
        walk(root, maxDepth: a.int("depth") ?? 10, maxNodes: a.int("max-nodes") ?? 1500) { n in
            let d = describe(n)
            // Skip anonymous layout groups to keep output small for models.
            let named = d["title"] != nil || d["description"] != nil || d["identifier"] != nil || d["value"] != nil
            let role = d["role"] as? String ?? ""
            let structural = ["AXGroup", "AXSplitGroup", "AXScrollArea", "AXLayoutArea", "AXUnknown"].contains(role)
            if !interestingOnly || named || !structural || n.depth <= 1 { nodes.append(d) }
            return true
        }
        return .json(["app": app.localizedName ?? "", "pid": Int(app.processIdentifier), "nodes": nodes])
    }

    static func find(_ a: Args) throws -> (NSRunningApplication, AXUIElement, String) {
        let (app, root) = try root(a)
        if let path = a.str("path"), path != "root" {
            var el = root
            for comp in path.split(separator: ".") {
                guard let i = Int(comp) else { throw ToolError("bad path '\(path)'") }
                let kids = children(el)
                guard i < kids.count else { throw ToolError("path '\(path)' no longer exists; re-run ax-tree") }
                el = kids[i]
            }
            return (app, el, path)
        }
        guard let query = a.str("query")?.lowercased() else { throw ToolError("pass --path or --query") }
        let role = a.str("role")
        var want = a.int("match") ?? 0
        var hit: (AXUIElement, String)?
        walk(root, maxDepth: 25, maxNodes: 5000) { n in
            if let role, axString(n.el, kAXRoleAttribute) != role { return true }
            let fields = [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute]
                .compactMap { axString(n.el, $0)?.lowercased() }
            if fields.contains(where: { $0 == query }) || fields.contains(where: { $0.contains(query) }) {
                if want == 0 { hit = (n.el, n.path); return false }
                want -= 1
            }
            return true
        }
        guard let hit else { throw ToolError("no element matching '\(query)'\(role.map { " with role \($0)" } ?? "")") }
        return (app, hit.0, hit.1)
    }

    static func press(_ a: Args) async throws -> Output {
        let (_, el, path) = try find(a)
        let action = a.str("action") ?? kAXPressAction
        let err = AXUIElementPerformAction(el, action as CFString)
        guard err == .success else { throw ToolError("\(action) failed on \(path): AXError \(err.rawValue)") }
        return .json(["ok": true, "path": path, "action": action, "element": describe(Node(el: el, path: path, depth: 0))])
    }

    static func setValue(_ a: Args) async throws -> Output {
        let (_, el, path) = try find(a)
        let value = try a.req("value")
        let err = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString)
        guard err == .success else { throw ToolError("setting value failed on \(path): AXError \(err.rawValue)") }
        return .json(["ok": true, "path": path, "element": describe(Node(el: el, path: path, depth: 0))])
    }
}
