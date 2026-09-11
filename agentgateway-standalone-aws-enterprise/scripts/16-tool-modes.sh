#!/bin/bash
# Tool modes: the same MCP listener presented four ways, measured by how many
# tool definitions a client has to accept before it can do anything.
#
# Enterprise only. The OSS proxy behaves as though toolMode is always standard,
# so part 1 of this lab cannot show any of this.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

TOK="$(mint_token all)"

count_tools() { # count_tools -> "<n> <names>"
  local sid names
  sid="$(mcp_init "$TOK")"
  names="$(tool_names "$TOK" "$sid")"
  printf '%s %s' "$(echo "$names" | tr ',' '\n' | grep -c . || true)" "$names"
}

show_mode() { # show_mode <mode> <expected-tool-count-or-empty>
  local mode="$1" want="${2:-}" n names
  hdr "toolMode: $mode"
  push_config_field toolMode "$mode"

  # A session picks up the mode that was in effect when it initialized, so every
  # measurement below starts a new session rather than reusing one.
  read -r n names <<<"$(count_tools)"
  log "a new session now sees $n tool definition(s)"
  echo "$names" | tr ',' '\n' | sed 's/^/    /'
  [[ -n "$want" ]] && expect "$mode presents $want tool(s) to the client" "$want" "$n"
  echo
}

cat <<'EOT'
  Every tool definition the gateway forwards is spent from the agent's context
  window before it does any work. Tool modes change what the client is given:

    standard    every tool on every target
    search      get_tool and invoke_tool: look a tool up, then call it
    code        run_code only, with the API for the allowed tools in its
                description, executed in a sandbox that maps calls back to MCP
    codeSearch  get_tool and run_code together

  The mode is a property of the listener, so all targets are presented the same
  way. Each change below is one config push to S3 and no restart.
EOT

# Baseline first, so the numbers that follow mean something.
show_mode standard
BASELINE="$(count_tools | cut -d' ' -f1)"
log "baseline: $BASELINE tool definitions across every target"

show_mode search 2
show_mode code 1
show_mode codeSearch 2

hdr "Calling a tool in code mode"
push_config_field toolMode code
SID="$(mcp_init "$TOK")"
log "run_code takes a script rather than a tool name. This one chains two calls"
log "that would otherwise be two round trips:"
mcp_rpc "$TOK" "$SID" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"run_code","arguments":{"code":"const who = await echo_whoami({}); return who;"}}}' \
  | jq -r '.result.content[0].text // (.error|tostring)' | head -c 600 | sed 's/^/    /'
echo; echo

hdr "Back to standard"
push_config_field toolMode standard
read -r n _ <<<"$(count_tools)"
expect "the fleet is back on the baseline tool list" "$BASELINE" "$n"

cat <<'EOT'

  What to take from the numbers: the tool list is a cost the agent pays on every
  session, and on a fleet it is a cost paid three times over because any node can
  answer. Search and code modes make that cost flat as the catalogue grows.
EOT

summary
