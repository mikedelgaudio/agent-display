import Foundation
import ApplicationServices
import CoreGraphics

struct Param {
    let name: String
    let type: String // "string" | "number" | "boolean"
    let required: Bool
    let help: String
    init(_ name: String, _ type: String = "string", required: Bool = false, _ help: String) {
        self.name = name; self.type = type; self.required = required; self.help = help
    }
}

struct Command {
    let name: String       // CLI name
    let tool: String       // MCP tool name
    let summary: String
    let params: [Param]
    let run: (Args, _ mcp: Bool) async throws -> Output
}

private let appP = Param("app", required: true, "Target app: pid, bundle id (com.example.MyApp) or name")
private let displayP = Param("display", "Display: agent display name, numeric ID, or 'main'. Default 'Agent Display'")
private let windowP = Param("window", "number", "Window index from `windows`; scopes the command to that window")
private let pathP = Param("path", "Element path from ax-tree (e.g. 0.3.1)")
private let queryP = Param("query", "Find element whose title/description/identifier/value contains this text")
private let roleP = Param("role", "Restrict --query to this AX role, e.g. AXButton, AXTextField")
private let matchP = Param("match", "number", "Use the Nth match of --query (0-based)")

let commands: [Command] = [
    Command(name: "start", tool: "display_start",
            summary: "Create a virtual display in the background (idempotent: returns the existing one if running).",
            params: [Param("name", "Display name (default 'Agent Display')"),
                     Param("width", "number", "Width in points (default 1920)"),
                     Param("height", "number", "Height in points (default 1080)"),
                     Param("hidpi", "boolean", "Retina (2x) backing store"),
                     Param("position", "Where to arrange it: right (default), left, above, below")],
            run: { a, _ in try await DisplayManager.start(a) }),
    Command(name: "stop", tool: "display_stop",
            summary: "Destroy a virtual display (windows on it move back to remaining displays).",
            params: [Param("name", "Display name (default 'Agent Display')"), Param("all", "boolean", "Stop every agent display")],
            run: { a, _ in try await DisplayManager.stop(a) }),
    Command(name: "list", tool: "display_list",
            summary: "List all active displays, marking agent-created virtual ones.",
            params: [], run: { _, _ in .json(listDisplays()) }),
    Command(name: "launch", tool: "app_launch",
            summary: "Launch an app WITHOUT activating it and put its windows on a display.",
            params: [Param("app", required: true, "App path (/path/My.app or a build product), bundle id, or name"), displayP,
                     Param("fill", "boolean", "Resize windows to fill the display"),
                     Param("args", "Space-separated launch arguments"),
                     Param("new-instance", "boolean", "Always start a new instance"),
                     Param("timeout", "number", "Seconds to wait for a window (default 15)")],
            run: { a, _ in try await Apps.launch(a) }),
    Command(name: "move", tool: "app_move",
            summary: "Move an already-running app's windows onto a display.",
            params: [appP, displayP, windowP, Param("fill", "boolean", "Resize windows to fill the display")],
            run: { a, _ in try await Apps.move(a) }),
    Command(name: "windows", tool: "app_windows",
            summary: "List an app's windows with frames and which display they are on.",
            params: [appP], run: { a, _ in try await Apps.windows(a) }),
    Command(name: "screenshot", tool: "screenshot",
            summary: "Capture a display (default the agent display) or an app's main window, without needing it to be visible to you.",
            params: [displayP, Param("app", "Capture this app's largest window instead of a display"),
                     Param("title", "With --app: pick the window whose title contains this"),
                     Param("max-dim", "number", "Downscale so the longest side is at most this many pixels"),
                     Param("out", "CLI only: output PNG path (default ./agent-display-<time>.png)")],
            run: { a, mcp in try await Capture.screenshot(a, defaultMaxDim: mcp ? 1568 : nil) }),
    Command(name: "ax-tree", tool: "ax_tree",
            summary: "Dump an app's accessibility tree (roles, titles, values, frames, paths).",
            params: [appP, windowP, Param("depth", "number", "Max depth (default 10)"),
                     Param("max-nodes", "number", "Max nodes visited (default 1500)"),
                     Param("all", "boolean", "Include anonymous layout groups")],
            run: { a, _ in try await AX.tree(a) }),
    Command(name: "ax-press", tool: "ax_press",
            summary: "Press a button/menu item/checkbox via Accessibility. No cursor movement, no focus change.",
            params: [appP, windowP, pathP, queryP, roleP, matchP, Param("action", "AX action (default AXPress), e.g. AXShowMenu, AXConfirm")],
            run: { a, _ in try await AX.press(a) }),
    Command(name: "ax-set-value", tool: "ax_set_value",
            summary: "Set a text field's (or slider's) value via Accessibility.",
            params: [appP, windowP, pathP, queryP, roleP, matchP, Param("value", required: true, "New value")],
            run: { a, _ in try await AX.setValue(a) }),
    Command(name: "key", tool: "key",
            summary: "Send key combos to one app (CGEventPostToPid), e.g. \"cmd+s\" or \"cmd+shift+z return\".",
            params: [appP, Param("keys", required: true, "Space-separated combos like cmd+s, return, tab, cmd+shift+z")],
            run: { a, _ in try await Input.key(a) }),
    Command(name: "type", tool: "type_text",
            summary: "Type text into the focused field of one app (CGEventPostToPid).",
            params: [appP, Param("text", required: true, "Text to type; \\n becomes Return")],
            run: { a, _ in try await Input.type(a) }),
    Command(name: "click", tool: "click",
            summary: "Click at x,y points relative to a display or app window, delivered only to that app. Best effort; prefer ax-press.",
            params: [appP, Param("x", "number", required: true, "X in points"), Param("y", "number", required: true, "Y in points"),
                     displayP, windowP, Param("button", "left (default) or right"), Param("count", "number", "Click count (2 = double-click)")],
            run: { a, _ in try await Input.click(a) }),
    Command(name: "permissions", tool: "permissions",
            summary: "Check (or with --prompt, request) Accessibility and Screen Recording permissions.",
            params: [Param("prompt", "boolean", "Show the system permission prompts")],
            run: { a, _ in
                if a.bool("prompt") == true {
                    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                    _ = CGRequestScreenCaptureAccess()
                }
                return .json([
                    "accessibility": AXIsProcessTrusted(),
                    "screenRecording": CGPreflightScreenCaptureAccess(),
                    "note": "Permissions belong to the app that launched agent-display (Terminal, iTerm, VS Code, Claude, etc.). Restart it after granting.",
                ])
            }),
]

func findCommand(_ name: String) -> Command? {
    commands.first { $0.name == name || $0.tool == name }
}
