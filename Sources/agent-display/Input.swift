import Foundation
import AppKit
import CoreGraphics

/// Synthetic input delivered straight to one process with CGEventPostToPid.
/// The user's real cursor position and keyboard focus are not touched.
enum Input {
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39,
        "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48,
        "space": 49, "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "home": 115, "pageup": 116,
        "forwarddelete": 117, "end": 119, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl,
        "fn": .maskSecondaryFn,
    ]

    static func pid(_ a: Args) throws -> pid_t {
        try requireAX()
        return try resolveApp(try a.req("app")).processIdentifier
    }

    /// --keys "cmd+s" or "cmd+shift+z" or "return". Several combos separated by spaces.
    static func key(_ a: Args) async throws -> Output {
        let target = try pid(a)
        let combos = try a.req("keys").split(separator: " ").map(String.init)
        for combo in combos {
            var flags: CGEventFlags = []
            var code: CGKeyCode?
            for part in combo.lowercased().split(separator: "+").map(String.init) {
                if let m = modifiers[part] { flags.insert(m) }
                else if let k = keyCodes[part] { code = k }
                else { throw ToolError("unknown key '\(part)'") }
            }
            guard let code else { throw ToolError("no key in combo '\(combo)'") }
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
                ev.flags = flags
                ev.postToPid(target)
                try await Task.sleep(nanoseconds: 15_000_000)
            }
        }
        return .json(["ok": true, "pid": Int(target), "keys": combos])
    }

    static func type(_ a: Args) async throws -> Output {
        let target = try pid(a)
        let text = try a.req("text")
        for ch in text {
            if ch == "\n" {
                for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)?.postToPid(target) }
            } else {
                let units = Array(String(ch).utf16)
                for down in [true, false] {
                    guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                    ev.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    ev.postToPid(target)
                }
            }
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        return .json(["ok": true, "pid": Int(target), "typed": text.count])
    }

    /// Click at (x, y) in points relative to --display (default: the agent display),
    /// or relative to the app's window when --window is given. Best effort: most
    /// Cocoa apps accept pid-targeted mouse events, some ignore them. Prefer ax-press.
    static func click(_ a: Args) async throws -> Output {
        let target = try pid(a)
        guard let x = a.double("x"), let y = a.double("y") else { throw ToolError("pass --x and --y (points)") }
        let origin: CGPoint
        if let wi = a.int("window") {
            let wins = axWindows(target)
            guard wi >= 0, wi < wins.count, let f = axFrame(wins[wi]) else { throw ToolError("window \(wi) not found") }
            origin = f.origin
        } else {
            origin = CGDisplayBounds(try resolveDisplay(a.str("display") ?? "Agent Display")).origin
        }
        let p = CGPoint(x: origin.x + x, y: origin.y + y)
        let right = a.str("button") == "right"
        let (downT, upT): (CGEventType, CGEventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        let count = max(1, a.int("count") ?? 1)
        for n in 1...count {
            for t in [downT, upT] {
                guard let ev = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: right ? .right : .left) else { continue }
                ev.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                ev.postToPid(target)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        return .json(["ok": true, "pid": Int(target), "globalPoint": ["x": Double(p.x), "y": Double(p.y)]])
    }
}
