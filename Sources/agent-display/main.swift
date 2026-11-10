import Foundation
import AppKit

let argv = Array(CommandLine.arguments.dropFirst())
let sub = argv.first ?? "help"

func printHelp() {
    print("""
    agent-display \(toolVersion): a private virtual monitor for AI agents on macOS.

    USAGE
      agent-display <command> [--option value ...]
      agent-display mcp            Run as an MCP server over stdio

    COMMANDS
    """)
    for c in commands {
        print("  \(c.name.padding(toLength: 14, withPad: " ", startingAt: 0))\(c.summary)")
        for p in c.params {
            let flag = "--\(p.name)" + (p.type == "boolean" ? "" : " <\(p.type)>")
            print("      \(flag.padding(toLength: 22, withPad: " ", startingAt: 0))\(p.required ? "(required) " : "")\(p.help)")
        }
    }
    print("""

    All commands print JSON. Exit code 1 on error with {"error": "..."}.
    """)
}

switch sub {
case "help", "--help", "-h":
    printHelp()
case "--version", "version":
    print(toolVersion)
case "create":
    // Foreground host process; `start` spawns this in the background.
    DisplayHost.runForeground(Args(Array(argv.dropFirst())))
case "mcp":
    _ = NSApplication.shared
    await MCPServer.serve()
default:
    guard let cmd = findCommand(sub) else {
        print(jsonString(["error": "unknown command '\(sub)'. Run `agent-display help`."]))
        exit(2)
    }
    _ = NSApplication.shared
    let args = Args(Array(argv.dropFirst()))
    do {
        switch try await cmd.run(args, false) {
        case .json(let v):
            print(jsonString(v, pretty: true))
        case .image(let png, var meta):
            let path = args.str("out") ?? "agent-display-\(Int(Date().timeIntervalSince1970)).png"
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try png.write(to: url)
            meta["path"] = url.path
            print(jsonString(meta, pretty: true))
        }
    } catch {
        print(jsonString(["error": "\(error)"], pretty: true))
        exit(1)
    }
}
