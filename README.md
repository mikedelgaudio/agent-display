# agent-display

**A private, invisible monitor for AI agents on macOS.**

Computer-use agents are great at building and testing Mac apps, but they take over your screen, cursor and keyboard while they work. `agent-display` gives the agent its own virtual monitor instead. The agent launches your app onto it, screenshots it, and drives it through Accessibility and per-process events, while you keep using your Mac normally.

```
┌──────────────────────┐   ┌──────────────────────┐
│  Your screen          │   │  "Agent Display"     │  ← software-only monitor
│  (you keep working)   │   │  your app under test │    (CGVirtualDisplay)
└──────────────────────┘   └──────────────────────┘
          ▲                              ▲
   your cursor & keyboard        agent: screenshots via ScreenCaptureKit,
                                 input via AXPress / CGEventPostToPid
```

Works with any agent that can run a shell command (Claude Code, Codex, Cursor, Aider, scripts) and with any MCP client via `agent-display mcp`.

## How it works

| Need | Technique | Touches your cursor/focus? |
| --- | --- | --- |
| A screen the agent owns | Private `CGVirtualDisplay` API in CoreGraphics (same approach as DeskPad / BetterDisplay) | No |
| Put the app there | Launch with `activates = false`, move windows via Accessibility | No |
| See it | `ScreenCaptureKit` captures the virtual display directly | No |
| Press buttons, fill fields | `AXUIElementPerformAction` / `AXUIElementSetAttributeValue` | No |
| Keyboard shortcuts, typing | `CGEventPostToPid` (events go to one process only) | No |
| Clicking at coordinates | `CGEventPostToPid` mouse events (best effort, some apps ignore them) | No |

The display exists only while its small host process runs. `stop` (or killing that process) removes it, and macOS moves any windows back to your real screens.

## Install

Requires macOS 14+ and Xcode command line tools.

```sh
git clone https://github.com/mikedelgaudio/agent-display.git
cd agent-display
./scripts/install.sh          # builds release and copies to /usr/local/bin (or ~/.local/bin)
agent-display permissions --prompt
```

Grant **Accessibility** and **Screen & System Audio Recording** to the app that runs the agent (Terminal, iTerm, VS Code, Cursor, the Claude app, etc.), then restart that app. Permissions belong to the parent app, not to `agent-display` itself.

## Quick start (CLI)

```sh
agent-display start --width 1600 --height 1000            # creates "Agent Display"
agent-display launch --app ./build/Debug/MyApp.app --fill  # opens without stealing focus
agent-display screenshot --out shot.png
agent-display ax-tree --app MyApp
agent-display ax-press --app MyApp --query "Sign In" --role AXButton
agent-display ax-set-value --app MyApp --query "Email" --value test@example.com
agent-display key --app MyApp --keys "cmd+s"
agent-display type --app MyApp --text "hello"
agent-display stop
```

Every command prints JSON; errors print `{"error": "..."}` with exit code 1. Run `agent-display help` for all options.

## Use as an MCP server

```json
{
  "mcpServers": {
    "agent-display": { "command": "agent-display", "args": ["mcp"] }
  }
}
```

Claude Code: `claude mcp add agent-display -- agent-display mcp`

Tools: `display_start`, `display_stop`, `display_list`, `app_launch`, `app_move`, `app_windows`, `screenshot` (returns the image), `ax_tree`, `ax_press`, `ax_set_value`, `key`, `type_text`, `click`, `permissions`.

## Use as an agent skill / instructions

- **Claude Code skill:** copy `skills/agent-display` into `~/.claude/skills/` (or your project's `.claude/skills/`).
- **Any other agent:** point it at [`AGENTS.md`](AGENTS.md), or paste it into your agent's instructions.

## Commands

| Command | What it does |
| --- | --- |
| `start` | Create a virtual display in the background. Idempotent. `--name --width --height --hidpi --position right\|left\|above\|below` |
| `stop` | Destroy it (`--name` or `--all`) |
| `list` | All active displays, virtual ones marked |
| `launch` | Launch an app (path, bundle id or name) without activating it, move its windows to the display |
| `move` | Move a running app's windows to a display |
| `windows` | An app's windows, frames and display |
| `screenshot` | PNG of a display or an app window. `--max-dim` to downscale; output includes `pointsPerPixel` |
| `ax-tree` | Accessibility tree with element paths |
| `ax-press` | Perform `AXPress` (or `--action`) on an element by `--path` or `--query` |
| `ax-set-value` | Set an element's value |
| `key` | Key combos to one app, e.g. `"cmd+shift+z return"` |
| `type` | Type text into one app |
| `click` | Click at points relative to a display or window, delivered to one app |
| `permissions` | Check or request Accessibility and Screen Recording |

## Caveats

- `CGVirtualDisplay` is **private, undocumented API**. It has worked since macOS 11 and is used by several shipping apps, but Apple could change it. Not App Store safe (this is a dev tool, so that is fine).
- macOS has one global cursor. The agent never moves it, but you *can* move your own cursor onto the virtual display. `--position` (default `right`) puts it at the edge of your arrangement to make that less likely.
- If "Displays have separate Spaces" is on, the virtual display gets its own menu bar and Space, which is usually what you want.
- Pid-targeted mouse clicks are not honored by every app (some games, Electron/Chromium surfaces). Prefer `ax-press`, `ax-set-value` and `key`.
- Some apps re-activate themselves on launch. That is the app's behavior; `launch` itself never activates.

## License

MIT
