---
name: agent-display
description: Run, screenshot and drive macOS GUI apps on a private virtual monitor so testing never takes over the user's screen, cursor or keyboard. Use when building or testing a Mac app, or whenever you would otherwise use computer use on this Mac.
---

# agent-display

`agent-display` is a CLI (also an MCP server via `agent-display mcp`) that creates a software-only monitor and lets you work on it with screenshots, Accessibility and per-process input. The user keeps using their Mac.

If `which agent-display` fails, tell the user to install it from the repo (`./scripts/install.sh`).

## Loop

1. `agent-display start` (idempotent)
2. Build, then `agent-display launch --app <path/to/App.app or bundle id> --fill`
3. `agent-display screenshot --out /tmp/agent-display.png --max-dim 1568`, then Read the PNG
4. `agent-display ax-tree --app <name>` to find elements and their `path`
5. Act, in order of preference:
   - `agent-display ax-press --app X --query "Save" --role AXButton` (or `--path 0.2.4`)
   - `agent-display ax-set-value --app X --query "Search" --value "foo"`
   - `agent-display key --app X --keys "cmd+s"`, `agent-display type --app X --text "hi"`
   - `agent-display click --app X --x 200 --y 120` (points on the agent display; image pixels × `pointsPerPixel`)
6. Screenshot again to verify.
7. After a rebuild: `agent-display key --app X --keys "cmd+q"`, then `launch` again.
8. `agent-display stop` when finished.

## Notes

- Every command prints JSON; errors are `{"error": "..."}`.
- Permission errors: ask the user to run `agent-display permissions --prompt` and grant Accessibility and Screen Recording to the app hosting you, then restart it. You cannot grant these yourself.
- Paths from `ax-tree` go stale after UI changes; re-run it.
- Never `open` an app without `-g` or activate it; that steals the user's focus.
