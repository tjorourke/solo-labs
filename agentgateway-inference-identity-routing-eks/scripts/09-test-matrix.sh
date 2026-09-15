#!/usr/bin/env bash
# The seven cases that are the lab: three identities, the two prompts, and one finance
# question for the restricted user.
#
#   ./scripts/09-test-matrix.sh
#
# Same prompt, different identity: different target. Same identity, different prompt:
# different model. Three things come back with every response and the table reads all
# three: x-routing-target is OPA's decision, x-vsr-selected-model is the router's, and
# the body's model field is the serving model's own statement of which model answered,
# which nothing on the gateway can fake. Exits non-zero on any miss.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
load_tokens; gw_up
FINANCE="What is IFRS 9 stage 2 impairment?"
# id | user | token | prompt | target | class | concrete model
CASES=(
  "A1|alice|$ALICE_TOKEN|$BASIC|openai|general|gpt-5.4-mini"
  "A2|alice|$ALICE_TOKEN|$HARD|openai|code|gpt-5.4"
  "B1|bob|$BOB_TOKEN|$BASIC|anthropic|general|claude-sonnet-5"
  "B2|bob|$BOB_TOKEN|$HARD|anthropic|code|claude-opus-5"
  "C1|carol|$CAROL_TOKEN|$BASIC|self-hosted|general|mistral-small-3.2-24b"
  "C2|carol|$CAROL_TOKEN|$HARD|self-hosted|code|qwen3-coder-30b"
  "C3|carol|$CAROL_TOKEN|$FINANCE|self-hosted|general|mistral-small-3.2-24b"
)
ok=0
printf "%-3s %-6s %-12s %-8s   %-3s %-12s %-8s %-4s %s\n" ID USER TARGET CLASS "" TARGET CLASS HTTP MODEL
printf "%-3s %-6s %-12s %-8s   %-3s %-12s %-8s %-4s %s\n" "" "" expected expected "" actual actual "" actual
for c in "${CASES[@]}"; do
  IFS='|' read -r id user tok prompt wtarget wclass wmodel <<<"$c"
  gw_curl "$tok" "$(chat "$prompt")"
  tgt="$(target)"; cls="$(class)"; model="$(resp_model)"
  good=0
  if [ "$tgt" = "$wtarget" ] && [ "$cls" = "$wclass" ] && [ "$STATUS" = 200 ] && [ "$model" = "$wmodel" ]; then good=1; fi
  ok=$((ok+good)); mark="ok"; [ $good = 1 ] || mark="X"
  printf "%-3s %-6s %-12s %-8s   %-3s %-12s %-8s %-4s %s\n" "$id" "$user" "$wtarget" "$wclass" "$mark" "${tgt:--}" "${cls:--}" "$STATUS" "$model"
done
echo; echo "matrix: $ok/${#CASES[@]} as expected"
[ "$ok" = "${#CASES[@]}" ]
