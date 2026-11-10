# Testing Mac GUI apps with agent-display

You have `agent-display`, a CLI that gives you a private virtual monitor on this Mac. Use it to run, see and drive GUI apps **without taking over the user's screen, cursor or keyboard**. Never use full-screen computer use for an app you can drive this way.

## Loop

1. `agent-display start` (idempotent; reuse it across tasks)
2. Build the app, then `agent-display launch --app <path/to/App.app or bundle id> --fill`
3. `agent-display screenshot --out /tmp/shot.png --max-dim 1568` and look at the image
4. `agent-display ax-tree --app <name>` to find elements and their `path`
5. Act, preferring the options that never touch the cursor:
   - `ax-press --app X --query "Save" --role AXButton` (or `--path 0.2.4`)
   - `ax-set-value --app X --query "Search" --value "foo"`
   - `key --app X --keys "cmd+s"` / `type --app X --text "hello"`
   - `click --app X --x 200 --y 120` only when nothing above works (points relative to the agent display; image pixels × `pointsPerPixel` from the screenshot)
6. Screenshot again to verify. Repeat.
7. After rebuilding, quit the old instance (`key --app X --keys "cmd+q"`) and `launch` again.
8. `agent-display stop` when the user no longer needs it.

## Rules

- All output is JSON. On `{"error": ...}` read the message: missing permissions must be granted by the user (`agent-display permissions --prompt`); you cannot grant them.
- Element `path`s go stale when the UI changes. Re-run `ax-tree` after anything that changes the window.
- Use `--window N` (from `windows`) when an app has several windows.
- Do not activate apps or use `open` without `-g`; that steals the user's focus.
