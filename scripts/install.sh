#!/usr/bin/env bash
# Build agent-display in release mode and install it on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/agent-display"

# Ad-hoc sign so macOS treats the binary consistently across rebuilds.
codesign --force --sign - "$BIN" >/dev/null 2>&1 || true

if [ -w /usr/local/bin ]; then
  DEST=/usr/local/bin
else
  DEST="$HOME/.local/bin"
  mkdir -p "$DEST"
fi
install -m 0755 "$BIN" "$DEST/agent-display"
echo "Installed $DEST/agent-display"
case ":$PATH:" in *":$DEST:"*) ;; *) echo "Add $DEST to your PATH." ;; esac

echo
echo "Next: agent-display permissions --prompt"
echo "Grant Accessibility and Screen Recording to the app that runs your agent, then restart it."
