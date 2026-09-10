#!/usr/bin/env bash
# Send the test set through the gateway and record which model answered.
#
#   ./scripts/02-test-routing.sh
#
# This is the test that counts. It goes client -> agentgateway -> ExtProc -> route ->
# backend -> model, and reads the answering model out of the response, so a pass means
# the whole path worked and not merely that the classifier had an opinion.
#
# The prompts here are held out. None of them appears in the candidate banks in
# yaml/00, because tuning the banks against this table and then publishing the table
# would not be a measurement of anything.
#
# Needs both models serving. ./scripts/00-verify-prereqs.sh checks that first.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib-context.sh"
resolve_ctx
kubectl() { command kubectl --context "$CTX" "$@"; }

POD="$(kubectl get pod -n models -l app=vllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$POD" ]; then
  echo "error: no pod matching -l app=vllm in namespace 'models'." >&2
  echo "  context in use: $CTX" >&2
  exit 1
fi
PHASE="$(kubectl get pod -n models "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [ "$PHASE" != "Running" ]; then
  echo "error: pod $POD is $PHASE, not Running. Both models must be serving." >&2
  echo "  if the GPU nodes are scaled to zero, run the model-routing lab's ./scripts/gpu.sh up" >&2
  exit 1
fi

kubectl exec -i -n models "$POD" -c vllm -- python3 - <<'PY'
import json, urllib.request

GW = ("http://model-gateway.agentgateway-system.svc.cluster.local"
      "/v1/chat/completions")

# id, prompt, expected model, what the case is for
CASES = [
    ("T1", "Explain optimistic concurrency control in two sentences.",
     "mistral", "basic explanation"),
    ("T2", "Two writers report successful updates to the same record, but one update "
           "disappears. Diagnose the failure and propose a safe write protocol.",
     "qwen", "diagnostic, same subject as T1"),
    ("T3", "What is the difference between readiness and liveness probes?",
     "mistral", "basic Kubernetes"),
    ("T4", "Readiness stays green while requests fail only during rollouts. Explain what "
           "evidence would distinguish draining problems from application failures.",
     "qwen", "diagnostic Kubernetes"),
    ("T5", "Give a one-sentence definition of a race condition.",
     "mistral", "hard vocabulary, basic ask"),
    ("T6", "Why can linearizable reads still fail to protect this read-modify-write "
           "operation?",
     "qwen", "short wording, deeper ask"),
    ("T7", "In a detailed answer with headings, examples, and a glossary, explain what an "
           "HTTP status code is.",
     "mistral", "verbose, still basic"),
    ("T8", "Explain the difference between a receipt and an invoice.",
     "mistral", "non-technical control"),
    ("T9", "Can you help me investigate an issue?",
     "mistral", "ambiguous, falls back"),
]

print(f"{'ID':4} {'WHAT THE CASE IS FOR':34} {'EXPECT':8} {'ANSWERED BY':24}")
print(f"{'-'*4} {'-'*34} {'-'*8} {'-'*24}")
ok = errors = 0
for cid, text, expect, why in CASES:
    body = {"model": "auto", "messages": [{"role": "user", "content": text}],
            "max_tokens": 16}
    req = urllib.request.Request(GW, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        served = json.load(urllib.request.urlopen(req, timeout=120)).get("model", "?")
    except Exception as e:
        # Errors get their own bucket. Folding them into either model would let a dead
        # run print a plausible score.
        errors += 1
        print(f"{cid:4} {why:34} {expect:8} ERROR {str(e)[:40]}")
        continue
    good = expect in served
    ok += good
    print(f"{cid:4} {why:34} {expect:8} {('ok  ' if good else 'X   ')+served:24}")

print()
if errors:
    print(f"{errors} of {len(CASES)} requests errored, so there is no score to report.")
    raise SystemExit(1)
print(f"routed as designed: {ok}/{len(CASES)}")
print()
print("T1 and T2 are the result to look at. Same domain, different model.")
PY
