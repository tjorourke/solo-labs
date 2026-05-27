#!/usr/bin/env bash
# Open two macOS Terminal tabs — one per cluster — running k9s.

set -Eeuo pipefail

[[ "$(uname)" == "Darwin" ]] || { echo "macOS-only (Terminal.app via osascript)"; exit 1; }
command -v k9s >/dev/null || { echo "k9s not on PATH — brew install k9s"; exit 1; }

for cluster in east west; do
  ctx="kind-${cluster}"
  echo "  → opening k9s tab for $cluster ($ctx)"
  osascript <<EOF
tell application "Terminal"
  activate
  tell application "System Events" to keystroke "t" using {command down}
  delay 0.4
  do script "k9s --context=$ctx" in front window
end tell
EOF
done

echo "  ✓ k9s tabs opened (⌘1 / ⌘2 to switch)"
echo
echo "Or run manually:"
echo "  k9s --context=kind-east"
echo "  k9s --context=kind-west"
