import Foundation

/// Minimal Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
enum MCPServer {
    static func serve() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let data = line.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard let id else { continue } // notification

            switch method {
            case "initialize":
                reply(id, result: [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "agent-display", "version": toolVersion],
                    "instructions": instructions,
                ])
            case "ping":
                reply(id, result: [String: Any]())
            case "tools/list":
                reply(id, result: ["tools": commands.map(toolSpec)])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = Args(dict: params["arguments"] as? [String: Any] ?? [:])
                guard let cmd = commands.first(where: { $0.tool == name }) else {
                    reply(id, error: (-32602, "unknown tool \(name)")); continue
                }
                do {
                    switch try await cmd.run(args, true) {
                    case .json(let v):
                        reply(id, result: ["content": [["type": "text", "text": jsonString(v)]], "isError": false])
                    case .image(let png, let meta):
                        reply(id, result: ["content": [
                            ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                            ["type": "text", "text": jsonString(meta)],
                        ], "isError": false])
                    }
                } catch {
                    reply(id, result: ["content": [["type": "text", "text": "\(error)"]], "isError": true])
                }
            default:
                reply(id, error: (-32601, "method not found: \(method)"))
            }
        }
    }

    static let instructions = """
    agent-display gives you a private, invisible monitor on this Mac so you can run and test GUI apps \
    without taking over the user's screen, cursor or keyboard. Typical loop: display_start -> \
    app_launch (with the built .app path) -> screenshot -> ax_tree -> ax_press / ax_set_value / key / type_text -> screenshot. \
    Prefer ax_press and ax_set_value over click: they never touch the cursor. Call display_stop when done.
    """

    static func toolSpec(_ c: Command) -> [String: Any] {
        var props: [String: Any] = [:]
        for p in c.params where p.name != "out" {
            props[p.name.replacingOccurrences(of: "-", with: "_")] = ["type": p.type, "description": p.help]
        }
        let required = c.params.filter(\.required).map { $0.name.replacingOccurrences(of: "-", with: "_") }
        return [
            "name": c.tool,
            "description": c.summary,
            "inputSchema": ["type": "object", "properties": props, "required": required],
        ]
    }

    static func reply(_ id: Any, result: Any) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func reply(_ id: Any, error: (Int, String)) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": error.0, "message": error.1]])
    }

    static func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
}
