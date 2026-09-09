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

# The lab root, so the script works from anywhere.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Cluster selection. Nothing here is tied to one cluster: by default it uses whatever
# kubectl context is current, which is what you want on kind or any cluster you are
# already pointed at. Set KUBE_CONTEXT to name one explicitly, or EKS_CLUSTER for the
# cloud case where the context name is an ARN nobody types by hand.
. "$HERE/scripts/lib-context.sh"
resolve_ctx
kubectl() { command kubectl --context "$CTX" "$@"; }

# Resolve the pod the requests are sent from. 2>/dev/null because kubectl prints a
# jsonpath template dump when the list is empty, which buries the real problem: you are
# pointed at the wrong cluster. A kind cluster stealing current-context is the usual
# cause, so say which context was used.
POD="$(kubectl get pod -n models -l app=vllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$POD" ]; then
  echo "error: no pod matching -l app=vllm in namespace 'models'." >&2
  echo "  context in use: $CTX" >&2
  echo "  set another with KUBE_CONTEXT=<name>, or EKS_CLUSTER=<cluster> for an EKS ARN." >&2
  echo "  contexts available:" >&2
  kubectl config get-contexts -o name 2>/dev/null | sed 's/^/    /' >&2
  exit 1
fi

# A Pending pod still has a name, so the check above passes and the first exec fails
# with "does not have a host assigned", which reads like a kubectl problem rather than
# what it is: the GPU nodes are scaled to zero. Say so.
PHASE="$(kubectl get pod -n models "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [ "$PHASE" != "Running" ]; then
  echo "error: pod $POD is $PHASE, not Running. Both models must be serving." >&2
  echo "  if the GPU nodes are scaled to zero:  ./scripts/gpu.sh up" >&2
  kubectl get pods -n models >&2
  exit 1
fi

# The prompt set is chosen to include the cases the keyword classifier gets wrong:
# four technical questions that avoid the listed vocabulary, and two finance
# questions that happen to contain a listed word.
run_set() {
  kubectl exec -i -n models "$POD" -- python3 - <<'PY'
import json, urllib.request
GW = ("http://model-gateway.agentgateway-system.svc.cluster.local"
      "/v1/chat/completions")
CASES = [
    ("finance", "What is IFRS 9 stage 2 impairment?"),
    ("finance", "Explain the difference between CVA and DVA in derivative pricing."),
    ("finance", "What capital must we hold against a stage 3 loan?"),
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
    # Bucket by the model that answered. An error is NOT a routing outcome, so it gets
    # its own bucket: folding errors into one of the two models makes a completely
    # failed run look like a plausible score, and both classifiers then tie because
    # both failed identically.
    if got.startswith("ERROR") or got in ("?", None):
        served = "error"
    elif "qwen" in got:
        served = "coding"
    elif "mistral" in got:
        served = "finance"
    else:
        served = "error"
    print("%s|%s|%s" % (want, q, served))
PY
}

echo "==> keyword classifier"
kubectl apply -f "$HERE/yaml-oss/20-routing-policy.yaml" -f "$HERE/yaml-oss/30-httproute.yaml" >/dev/null
sleep 8
run_set > /tmp/rung2.txt

echo "==> semantic classifier"
kubectl apply -f "$HERE/yaml-oss/80-semantic-router-extproc.yaml" -f "$HERE/yaml-oss/81-httproute-vsr.yaml" >/dev/null
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

errs=$(cat /tmp/rung2.txt /tmp/rung3.txt | awk -F'|' '$3=="error"' | wc -l | tr -d ' ')
if [ "$errs" != "0" ]; then
  echo
  echo "ERROR: $errs of the requests did not reach a model, so there is nothing to score." >&2
  echo "  Check the gateway exists and the route is attached:" >&2
  echo "    kubectl --context \"$CTX\" -n agentgateway-system get gateway,httproute" >&2
  exit 1
fi

w2=$(paste -d'|' /tmp/rung2.txt /tmp/rung3.txt | awk -F'|' '$1!=$3' | wc -l | tr -d ' ')
w3=$(paste -d'|' /tmp/rung2.txt /tmp/rung3.txt | awk -F'|' '$4!=$6' | wc -l | tr -d ' ')
n=$(wc -l < /tmp/rung2.txt | tr -d ' ')
echo
echo "keyword classifier:  $((n-w2))/$n correct"
echo "semantic classifier: $((n-w3))/$n correct"
echo
echo "semantic classification is left applied. Return to the keyword classifier with:"
echo "  kubectl apply -f yaml-oss/20-routing-policy.yaml -f yaml-oss/30-httproute.yaml"
