#!/usr/bin/env bash
# The flow, end to end: bob's five prompts at one endpoint, then alice's one.
#
#   ./scripts/06-test-flow.sh
#
# bob may use private models and the approved frontier. He never chooses; the task does, and
# the table says a review or a modification stays private whatever his permissions. alice
# is private only, so her generic question uses a suitable private model. Three things come
# back with every response and the table reads all three: x-model-pool and x-model-class
# are OPA's decision, x-vsr-selected-model is the router's task label, and the body's model
# field is the serving model's own statement of which model answered. Exits non-zero on any
# miss.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
load_tokens; gw_up
# id | user | token | prompt | task | pool | class | model
CASES=(
  "B1|bob|$BOB_TOKEN|Show a Java dependency-injection example.|generic_coding|approved-frontier|coding|claude-sonnet-5"
  "B2|bob|$BOB_TOKEN|Review this function for concurrency bugs: public void credit(long amt) { balance += amt; }|code_review|private|coding|qwen3-coder-30b"
  "B3|bob|$BOB_TOKEN|Modify this settlement-service function so retries are idempotent: def settle(tx): post(tx); mark_done(tx)|code_modification|private|coding|qwen3-coder-30b"
  "B4|bob|$BOB_TOKEN|Explain the duration risk in this bond portfolio.|finance|private|finance|mistral-small-3.2-24b"
  "B5|bob|$BOB_TOKEN|Can you improve this?|uncertain|private|general|mistral-small-3.2-24b"
  "A1|alice|$ALICE_TOKEN|Show a Java dependency-injection example.|generic_coding|private|coding|qwen3-coder-30b"
)
ok=0
printf "%-3s %-6s %-18s %-18s %-8s   %-3s %-18s %-8s %-4s %s\n" ID USER TASK POOL CLASS "" POOL CLASS HTTP MODEL
printf "%-3s %-6s %-18s %-18s %-8s   %-3s %-18s %-8s %-4s %s\n" "" "" "router" expected expected "" actual actual "" actual
for c in "${CASES[@]}"; do
  IFS='|' read -r id user tok prompt wtask wpool wclass wmodel <<<"$c"
  gw_curl "$tok" "$(chat "$prompt")"
  t="$(task)"; p="$(pool)"; cl="$(mclass)"; model="$(resp_model)"
  good=0
  if [ "$t" = "$wtask" ] && [ "$p" = "$wpool" ] && [ "$cl" = "$wclass" ] && [ "$STATUS" = 200 ] && [ "$model" = "$wmodel" ]; then good=1; fi
  ok=$((ok+good)); mark="ok"; [ $good = 1 ] || mark="X"
  printf "%-3s %-6s %-18s %-18s %-8s   %-3s %-18s %-8s %-4s %s\n" "$id" "$user" "${t:--}" "$wpool" "$wclass" "$mark" "${p:--}" "${cl:--}" "$STATUS" "$model"
done
echo; echo "flow: $ok/${#CASES[@]} as expected"
[ "$ok" = "${#CASES[@]}" ]
