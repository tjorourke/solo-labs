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
# already pointed at. Set KUBE_CONTEXT to name one explicitly.
#
# The EKS block is a convenience for the cloud case, where a context name is an ARN
# nobody types by hand. Set EKS_CLUSTER (and optionally AWS_PROFILE and AWS_REGION) and
# the context is derived from the account the profile resolves to.
if [ -n "${KUBE_CONTEXT:-}" ]; then
  CTX="$KUBE_CONTEXT"
elif [ -n "${EKS_CLUSTER:-}" ]; then
  REGION="${AWS_REGION:-eu-west-2}"
  ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
  [ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] \
    || { echo "error: no AWS identity. Check AWS_PROFILE, or run aws sso login." >&2; exit 1; }
  CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${EKS_CLUSTER}"
else
  CTX="$(kubectl config current-context 2>/dev/null)"
  [ -n "$CTX" ] || { echo "error: no current kubectl context, and neither KUBE_CONTEXT nor EKS_CLUSTER is set." >&2; exit 1; }
fi
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
echo "  kubectl apply -f yaml/20-routing-policy.yaml -f yaml/30-httproute.yaml"
