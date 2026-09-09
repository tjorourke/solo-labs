#!/usr/bin/env bash
# Run the same prompts through the keyword classifier and the semantic classifier and
# print them side by side. This is the A/B that makes the case for semantic classification, and it is
# worth running live rather than quoting, because the failures are the interesting
# part and they are specific to the wording you use.
#
#   ./scripts/test-rungs.sh
#
# It switches the policy twice and leaves semantic classification applied at the end.
set -euo pipefail

: "${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
export AWS_PROFILE="$SOVEREIGN_AWS_PROFILE"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kubectl() { command kubectl --context "$CTX" "$@"; }

POD="$(kubectl get pod -n models -l app=vllm -o jsonpath='{.items[0].metadata.name}')"
[ -n "$POD" ] || { echo "error: no vLLM pod in models" >&2; exit 1; }

# The prompt set is chosen to include the cases the keyword classifier gets wrong:
# four technical questions that avoid the listed vocabulary, and two finance
# questions that happen to contain a listed word.
run_set() {
  kubectl exec -i -n models "$POD" -- python3 - <<'PY'
import json, urllib.request
GW = ("http://sovereign-gateway-internal.agentgateway-system.svc.cluster.local"
      "/v1/chat/completions")
CASES = [
    ("finance", "What is IFRS 9 stage 2 impairment?"),
    ("finance", "Explain the difference between CVA and DVA in derivative pricing."),
    ("finance", "What is our Python licensing spend this quarter?"),
    ("finance", "Model the credit risk function for our loan book."),
    ("coding",  "Write a Python function that reverses a linked list."),
    ("coding",  "Why is my pod stuck in CrashLoopBackOff?"),
    ("coding",  "Make this run faster without the inner loop."),
    ("coding",  "Write a Golang handler for an S3 upload."),
    ("coding",  "How do I set a Terraform provider version?"),
]
for want, q in CASES:
    body = {"model": "auto", "max_tokens": 6,
            "messages": [{"role": "user", "content": q}]}
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            GW, data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"}), timeout=180)
        got = json.load(r).get("model", "?")
    except Exception as e:
        got = "ERROR %s" % e
    served = "coding" if "qwen" in got else "finance"
    print("%s|%s|%s" % (want, q, served))
PY
}

echo "==> keyword classifier"
kubectl apply -f "$HERE/yaml/20-routing-policy.yaml" -f "$HERE/yaml/30-httproute.yaml" >/dev/null
sleep 8
run_set > /tmp/rung2.txt

echo "==> semantic classifier"
kubectl apply -f "$HERE/yaml/80-semantic-router-extproc.yaml" -f "$HERE/yaml/81-httproute-vsr.yaml" >/dev/null
sleep 8
run_set > /tmp/rung3.txt

echo
printf "%-52s %-8s %-10s %-10s\n" "PROMPT" "SHOULD" "KEYWORD" "SEMANTIC"
printf "%-52s %-8s %-10s %-10s\n" "----------------------------------------------------" "--------" "----------" "----------"
paste -d'|' /tmp/rung2.txt /tmp/rung3.txt | while IFS='|' read -r want q got2 want3 q3 got3; do
  m2="ok "; [ "$got2" != "$want" ] && m2="X  "
  m3="ok "; [ "$got3" != "$want" ] && m3="X  "
  printf "%-52s %-8s %s%-7s %s%-7s\n" "$(echo "$q" | cut -c1-50)" "$want" "$m2" "$got2" "$m3" "$got3"
done

w2=$(paste -d'|' /tmp/rung2.txt /tmp/rung3.txt | awk -F'|' '$1!=$3' | wc -l | tr -d ' ')
w3=$(paste -d'|' /tmp/rung2.txt /tmp/rung3.txt | awk -F'|' '$4!=$6' | wc -l | tr -d ' ')
n=$(wc -l < /tmp/rung2.txt | tr -d ' ')
echo
echo "keyword classifier:  $((n-w2))/$n correct"
echo "semantic classifier: $((n-w3))/$n correct"
echo
echo "semantic classification is left applied. Return to the keyword classifier with:"
echo "  kubectl apply -f yaml/20-routing-policy.yaml -f yaml/30-httproute.yaml"
