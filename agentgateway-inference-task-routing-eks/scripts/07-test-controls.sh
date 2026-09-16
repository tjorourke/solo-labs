#!/usr/bin/env bash
# The controls: what the data checks and the permissions refuse or redirect.
#
#   ./scripts/07-test-controls.sh
#
# C1 and C2 are evidence that overrides a generic classification: the bank's own code in the
# prompt, and a provenance header from an application that knows where the code came from.
# Both keep a generic question private. C3 is the same evidence in the form an editor sends\n# it, file paths rather than package names. C4 is a credential in the prompt: blocked, not
# routed. C4 is dave, who may use the frontier only, asking for a review: reviews are
# private, he may not use private, so an error and nothing sent anywhere. C5 to C7 are
# spoofing attempts that must change nothing. C8 and C9 are tokens that never reach OPA.
# Exits non-zero on any miss.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
load_tokens; gw_up
MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
opa_decisions() { kubectl -n "$NS" logs deploy/opa --since-time="$MARK" 2>/dev/null | grep -c '"decision_id"' || true; }
err_msg() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("error",{}).get("message",""))
except Exception: print(open(sys.argv[1]).read()[:60])' "$BODY"; }
ok=0; n=0
row() { n=$((n+1)); ok=$((ok+$1)); local mark="ok"; [ "$1" = 1 ] || mark="X "; printf "%-3s %-70s %s %s\n" "C$n" "$2" "$mark" "$3"; }
t() { [ "$1" = "$2" ] && echo 1 || echo 0; }
GENERIC="Show a Java dependency-injection example."

gw_curl "$BOB_TOKEN" "$(chat "Show a Java dependency-injection example, following the style of com.example.internal.payments.")"
row $(t "$(pool)/$(mclass)/$(resp_model)" private/coding/qwen3-coder-30b) "bob, generic question that names the bank's own package" "pool=$(pool) reason=\"$(reason)\""
gw_curl "$BOB_TOKEN" "$(chat "$GENERIC")" -H 'x-source-repo: git.internal/payments/settlement-service'
row $(t "$(pool)/$(mclass)" private/coding) "bob, generic question with x-source-repo from an internal repository" "pool=$(pool) reason=\"$(reason)\""
# An editor does not send the question on its own. It wraps it in an envelope: the files the
# person has open, its own tool definitions, then the question. The classifier reads the whole
# thing and a few lines about bonds sit inside a payload of Java paths, so it reads as coding,
# which is the one task that may leave. The evidence check is what holds it: the paths are the
# bank's own code, in the form an editor writes them.
EDITOR_ENVELOPE='<open_and_recently_viewed_files>
Recently viewed files (recent at the top, oldest at the bottom):
- /home/dev/src/finance-app/ledger-core/src/main/java/com/example/internal/ledger/LedgerCore.java (total lines: 122)
</open_and_recently_viewed_files>
<user_query>
Explain the duration risk in a bond portfolio holding a 4.25 per cent 2030 gilt.
</user_query>'
gw_curl "$BOB_TOKEN" "$(chat "$EDITOR_ENVELOPE")"
row $(t "$(pool)" private) "bob asks from an editor, with the bank's files in the envelope" "pool=$(pool) task=$(task) reason=\"$(reason)\""

gw_curl "$BOB_TOKEN" "$(chat "Show a Java dependency-injection example that uses AKIAIOSFODNN7EXAMPLE as the key.")"
row $(t "$STATUS" 422) "bob, prompt containing something shaped like an access key" "$STATUS $(err_msg)"
gw_curl "$DAVE_TOKEN" "$(chat "Review this function for concurrency bugs: public void credit(long amt) { balance += amt; }")"
row $(t "$STATUS" 403) "dave (frontier only) asks for a code review" "$STATUS $(err_msg)"

gw_curl "$ALICE_TOKEN" "$(chat "$GENERIC")" -H 'x-model-pool: approved-frontier' -H 'x-model-class: coding'
row $(t "$(pool)" private) "alice sends x-model-pool: approved-frontier" "pool=$(pool)"
gw_curl "$BOB_TOKEN" "$(chat "Review this function for concurrency bugs: public void credit(long amt) { balance += amt; }")" -H 'x-selected-model: generic_coding'
row $(t "$(task)/$(pool)" code_review/private) "bob sends x-selected-model: generic_coding with a review" "task=$(task) pool=$(pool)"
gw_curl "$BOB_TOKEN" "$(chat "$GENERIC" claude-sonnet-5)"
row $(t "$STATUS" 400) "bob names the frontier model in the body" "$STATUS $(err_msg)"

before=$(opa_decisions)
gw_curl - "$(chat "$GENERIC")"
row $(t "$STATUS/$(opa_decisions)" "401/$before") "no token" "$STATUS, OPA not called"
gw_curl "$BADSIG_TOKEN" "$(chat "$GENERIC")"
row $(t "$STATUS/$(opa_decisions)" "401/$before") "token signed by a key that is not in the JWKS" "$STATUS, OPA not called"
echo; echo "controls: $ok/$n as expected"
[ "$ok" = "$n" ]
