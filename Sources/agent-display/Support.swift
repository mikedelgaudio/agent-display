import Foundation
import CoreGraphics

let toolVersion = "0.1.0"

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// Result of running a command. CLI prints JSON (and writes images to disk);
/// the MCP server returns JSON as text content and images as image content.
enum Output {
    case json(Any)
    case image(png: Data, meta: [String: Any])
}

/// Uniform argument bag shared by the CLI (`--key value`) and MCP (`{"key": value}`).
struct Args {
    var positional: [String] = []
    var opts: [String: String] = [:]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                var key = String(a.dropFirst(2))
                if let eq = key.firstIndex(of: "=") {
                    opts[String(key[..<eq])] = String(key[key.index(after: eq)...])
                    i += 1
                    continue
                }
                key = key.replacingOccurrences(of: "_", with: "-")
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    opts[key] = argv[i + 1]
                    i += 2
                } else {
                    opts[key] = "true"
                    i += 1
                }
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    init(dict: [String: Any]) {
        for (k, v) in dict {
            let key = k.replacingOccurrences(of: "_", with: "-")
            switch v {
            case let s as String: opts[key] = s
            case let b as Bool: opts[key] = b ? "true" : "false"
            case let n as NSNumber: opts[key] = n.stringValue
            default: opts[key] = "\(v)"
            }
        }
    }

    func str(_ k: String) -> String? { opts[k] }
    func req(_ k: String) throws -> String {
        guard let v = opts[k], !v.isEmpty else { throw ToolError("missing required argument --\(k)") }
        return v
    }
    func int(_ k: String) -> Int? { opts[k].flatMap { Int($0) ?? Double($0).map { Int($0) } } }
    func double(_ k: String) -> Double? { opts[k].flatMap { Double($0) } }
    func bool(_ k: String) -> Bool? {
        guard let v = opts[k]?.lowercased() else { return nil }
        return ["1", "true", "yes", "on"].contains(v)
    }
}

func jsonString(_ value: Any, pretty: Bool = false) -> String {
    let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber,
          let data = try? JSONSerialization.data(withJSONObject: value, options: opts.union(.fragmentsAllowed)),
          let s = String(data: data, encoding: .utf8) else { return "\"\(value)\"" }
    return s
}

func rectDict(_ r: CGRect) -> [String: Any] {
    ["x": Double(r.origin.x), "y": Double(r.origin.y), "width": Double(r.size.width), "height": Double(r.size.height)]
}

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}
