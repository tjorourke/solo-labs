#!/usr/bin/env bash
# Opens two Terminal.app tabs with k9s — one per cluster.
# macOS only. Requires k9s installed.

set -e
CLUSTER1="${CLUSTER1:-kind-east-ag}"
CLUSTER2="${CLUSTER2:-kind-west-ag}"

if ! command -v k9s >/dev/null 2>&1; then
  echo "k9s not found — install with: brew install k9s"
  exit 1
fi

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Not macOS — run these in two separate terminals yourself:"
  echo "  k9s --context $CLUSTER1"
  echo "  k9s --context $CLUSTER2"
  exit 0
fi

# Use `selected tab of front window` rather than `tab 2 of window 1`. The
# Cmd+T keystroke creates a new tab and selects it, but indexing it as
# "tab 2" is fragile (any pre-existing tabs in window 1 throw it off).
# `selected tab of front window` reliably points at the freshly-opened tab.
if ! osascript <<EOF 2>/tmp/k9s-tabs.err
tell application "Terminal"
  activate
  do script "k9s --context $CLUSTER1"
  delay 0.8
end tell
tell application "System Events" to keystroke "t" using {command down}
delay 0.8
tell application "Terminal"
  do script "k9s --context $CLUSTER2" in selected tab of front window
end tell
EOF
then
  echo "AppleScript failed — Terminal may need Accessibility permission for"
  echo "'System Events'. System Settings > Privacy & Security > Accessibility >"
  echo "enable 'Terminal'. Fallback — run these yourself in two tabs:"
  echo "  k9s --context $CLUSTER1"
  echo "  k9s --context $CLUSTER2"
  cat /tmp/k9s-tabs.err >&2
  exit 1
fi
