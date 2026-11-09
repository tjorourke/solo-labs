#!/usr/bin/env bash
# Adds or removes the lab's Codex MCP entries in ~/.codex/config.toml. Leaves every other line alone,
# and never touches Claude Code. Key names checked against https://developers.openai.com/codex/mcp.md
# and codex-rs/cli/src/mcp_cmd.rs @ rust-v0.167.0.
#
#   ./scripts/codex-config.sh show            print the exact change, write nothing
#   ./scripts/codex-config.sh apply           back up, then add the entries
#   ./scripts/codex-config.sh bearer          switch lab-cloud-a to bearer_token_env_var = "LAB_MCP_TOKEN"
#   ./scripts/codex-config.sh oauth           switch lab-cloud-a back to Keycloak sign-in
#   ./scripts/codex-config.sh remove          back up, then strip only the lab entries
#
# TOML note: mcp_oauth_callback_port is a top-level key. Appended after an existing [table] it would become part
# of that table, so it goes in above the first table header. The tables go at the end. Same content as approved.
set -euo pipefail
CFG=${CODEX_CONFIG:-$HOME/.codex/config.toml}
TOP_BEGIN='# >>> xcloud-mcp lab (top-level) >>>'
TOP_END='# <<< xcloud-mcp lab (top-level) <<<'
BEGIN='# >>> xcloud-mcp lab >>>'
END='# <<< xcloud-mcp lab <<<'

top_block() { printf '%s\nmcp_oauth_callback_port = 5555\n\n%s\n' "$TOP_BEGIN" "$TOP_END"; }
tables_block() {
  local mode=${1:-oauth}
  echo "$BEGIN"
  echo
  cat <<'T'
[mcp_servers.lab-registry]
url = "http://localhost:31313/mcp"
bearer_token_env_var = "LAB_AR_TOKEN"

[mcp_servers.lab-cloud-a]
url = "http://localhost:8080/registry/cloud-a"
T
  if [[ $mode == oauth ]]; then
    cat <<'T'
scopes = ["openid", "profile"]

[mcp_servers.lab-cloud-a.oauth]
client_id = "codex-mcp"
callback_url = "http://127.0.0.1:5555/callback"
T
  else
    echo 'bearer_token_env_var = "LAB_MCP_TOKEN"'
  fi
  echo "$END"
}

backup() { [[ -f $CFG ]] && cp -p "$CFG" "$CFG.bak.$(date +%Y%m%d-%H%M%S)" && echo "Backup: $CFG.bak.$(date +%Y%m%d-%H%M%S)"; return 0; }

strip() {  # removes both marked blocks, prints the rest
  awk -v a="$TOP_BEGIN" -v b="$TOP_END" -v c="$BEGIN" -v d="$END" '
    $0==a||$0==c {skip=1; next} $0==b||$0==d {skip=0; next} !skip' "$CFG"
}

validate() {
  python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$1" \
    || { echo "Result is not valid TOML. $CFG left unchanged." >&2; exit 1; }
}

write() {  # write MODE
  local mode=$1 tmp rest top tables
  tmp=$(mktemp); rest=$(mktemp); top=$(mktemp); tables=$(mktemp)
  if [[ -f $CFG ]]; then strip >"$rest"; fi
  if grep -Eq '^[[:space:]]*mcp_oauth_callback_port[[:space:]]*=' "$rest"; then
    echo "$CFG already sets mcp_oauth_callback_port. Not changing it; sort that out by hand first." >&2; exit 1
  fi
  if grep -Eq '^\[mcp_servers\.lab-(registry|cloud-a)' "$rest"; then
    echo "$CFG already has lab-registry or lab-cloud-a outside the lab markers. Not touching it." >&2; exit 1
  fi
  top_block >"$top"; tables_block "$mode" >"$tables"
  python3 - "$rest" "$top" "$tables" "$tmp" <<'PY'
import sys
rest, top, tables, out = (open(p).read() for p in sys.argv[1:4]) , None, None, sys.argv[4]
rest, top, tables = list(rest)
lines = rest.splitlines(keepends=True)
if lines and not lines[-1].endswith("\n"):
    lines[-1] += "\n"
i = next((n for n, l in enumerate(lines) if l.lstrip().startswith("[")), len(lines))
text = "".join(lines[:i]) + top + "".join(lines[i:]) + tables
open(out, "w").write(text)
PY
  validate "$tmp"
  mkdir -p "$(dirname "$CFG")"
  mv "$tmp" "$CFG"
  rm -f "$rest" "$top" "$tables"
}

case "${1:-show}" in
  show)
    echo "Would add this above the first [table] in $CFG:"; top_block
    echo; echo "and this at the end:"; tables_block oauth ;;
  apply)  backup; write oauth; echo "Added the lab entries to $CFG" ;;
  bearer) [[ -f $CFG ]] && grep -qF "$BEGIN" "$CFG" || { echo 'Run apply first' >&2; exit 1; }
          backup; write bearer; echo 'lab-cloud-a now uses LAB_MCP_TOKEN. Export it from ./scripts/mint-token.sh, then restart Codex.' ;;
  oauth)  [[ -f $CFG ]] && grep -qF "$BEGIN" "$CFG" || { echo 'Run apply first' >&2; exit 1; }
          backup; write oauth; echo 'lab-cloud-a back on Keycloak sign-in. Run: codex mcp login lab-cloud-a' ;;
  remove) [[ -f $CFG ]] || { echo "No $CFG"; exit 0; }
          backup; tmp=$(mktemp); strip >"$tmp"; validate "$tmp"; mv "$tmp" "$CFG"
          grep -qF 'xcloud-mcp lab' "$CFG" && { echo 'Lab markers still present' >&2; exit 1; } || echo "Lab entries removed from $CFG" ;;
  *) echo 'Usage: codex-config.sh {show|apply|bearer|oauth|remove}' >&2; exit 2 ;;
esac
