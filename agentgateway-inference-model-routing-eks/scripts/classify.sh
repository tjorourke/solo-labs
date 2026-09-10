#!/usr/bin/env bash
# Run the nine prompts through the semantic router's own classification API.
#
#   ./scripts/classify.sh
#
# This is the cheap check. It talks to vSR directly instead of sending a request through
# the gateway to a model, so it needs no GPU nodes and costs nothing: it proves the
# classifier and the domain-to-model mapping in yaml/70, which is the half of the lab
# most likely to break on a version bump.
#
# What it does NOT prove is the path: the PreRouting ExtProc call, the x-selected-model
# header, the HTTPRoute match and the backend rewrite. For that the models have to be
# serving, so bring the GPUs up and run ./scripts/test-classifiers.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib-context.sh"
resolve_ctx
kubectl() { command kubectl --context "$CTX" "$@"; }

POD="$(kubectl get pod -n agentgateway-system -l app.kubernetes.io/name=semantic-router \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$POD" ]; then
  echo "error: no semantic-router pod in namespace 'agentgateway-system'." >&2
  echo "  context in use: $CTX" >&2
  echo "  install it with ./scripts/05-semantic-router.sh" >&2
  exit 1
fi

# The API listens on 127.0.0.1 inside the pod, so the request is made from in there.
kubectl exec -i -n agentgateway-system "$POD" -- python3 - <<'PY'
import json, urllib.request

API = "http://127.0.0.1:8080/api/v1/classify/intent"
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
WANT = {"finance": "mistral-small-3.2-24b", "coding": "qwen3-coder-30b"}

ok = errors = 0
print(f"{'PROMPT':52} {'SHOULD':8} {'CHOSE':24} {'DOMAIN':17} CONF")
for want, text in CASES:
    req = urllib.request.Request(
        API, data=json.dumps({"text": text}).encode(),
        headers={"Content-Type": "application/json"})
    try:
        r = json.load(urllib.request.urlopen(req, timeout=30))
    except Exception as e:
        # Errors get their own bucket. Counting them as one of the two models makes a
        # dead run print a plausible-looking score.
        errors += 1
        print(f"{text[:52]:52} {want:8} {'ERROR ' + str(e)[:60]}")
        continue
    model = r.get("recommended_model")
    domain = ",".join(r.get("matched_signals", {}).get("domains", [])) or "-"
    conf = r.get("classification", {}).get("confidence", 0)
    good = model == WANT[want]
    ok += good
    print(f"{text[:52]:52} {want:8} {('ok   ' if good else 'X    ') + str(model):24} {domain:17} {conf:.3f}")

print()
if errors:
    print(f"{errors} of {len(CASES)} prompts errored, so there is no score to report.")
    raise SystemExit(1)
print(f"semantic classifier: {ok}/{len(CASES)} correct")
PY
