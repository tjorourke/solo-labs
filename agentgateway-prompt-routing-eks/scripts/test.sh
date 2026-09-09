#!/usr/bin/env bash
# Prove the gateway routes on the prompt, not on the client.
#
# Seven requests, all to one endpoint. Six send "model": "auto" and never name a
# model; the seventh names one to prove classification is bypassed when a client has
# already chosen.
#
# The model that answered is read out of the response body, which is the model vLLM
# itself reports. The gateway access log is the second and better proof because it
# shows route= and endpoint=, and endpoint= cannot be faked by a backend pinning a
# name. teardown prints the command for it.
#
# Runs from inside the cluster, out of the vLLM pod, for one reason worth knowing:
# the parent lab's Kyverno policies refuse an ad-hoc debug pod in the models
# namespace (resource limits, the restricted PSS subset, and an unsigned curl image).
# That is the hardening working, not an obstacle to route around.
set -euo pipefail

: "${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
export AWS_PROFILE="$SOVEREIGN_AWS_PROFILE"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kubectl() { command kubectl --context "$CTX" "$@"; }

POD="$(kubectl get pod -n models -l app=vllm -o jsonpath='{.items[0].metadata.name}')"
[ -n "$POD" ] || { echo "error: no vLLM pod in models" >&2; exit 1; }

# Piped over stdin rather than staged with `kubectl cp`. cp into this pod fails and,
# under `set -e`, takes the whole script down without printing anything at all, which
# reads as "the test produced no output" rather than as an error.
kubectl exec -i -n models "$POD" -- python3 - <<'PY'
import json, sys, urllib.request

GW = ("http://sovereign-gateway-internal.agentgateway-system.svc.cluster.local"
      "/v1/chat/completions")

def parts(t):
    # The shape ADK and LiteLLM-based agents send. Classifying only the plain
    # string shape sends every one of these to the default model, silently.
    return [{"type": "text", "text": t}]

CASES = [
    ("FIN str",   "What is IFRS 9 stage 2 impairment?",                        "s",   "mistral-small-3.2-24b"),
    ("FIN parts", "Explain the difference between CVA and DVA in derivative pricing.", "p", "mistral-small-3.2-24b"),
    ("FIN str",   "Summarise our Q3 results for the board.",                   "s",   "mistral-small-3.2-24b"),
    ("COD str",   "Write a Python function to reverse a linked list.",         "s",   "qwen3-coder-30b"),
    ("COD parts", "Refactor this to remove the nested loop and add a unit test.", "p", "qwen3-coder-30b"),
    ("COD parts", "Debug why my SQL query returns duplicates.",                "p",   "qwen3-coder-30b"),
    ("PINNED",    "Ignore classification, I named the model.",                 "pin", "qwen3-coder-30b"),
]

fails = 0
for label, q, shape, want in CASES:
    msgs = [{"role": "system", "content": "You are a helpful analyst."},
            {"role": "user", "content": parts(q) if shape == "p" else q}]
    body = {"model": "auto", "max_tokens": 8, "messages": msgs}
    if shape == "pin":
        body["model"] = "qwen3-coder-30b"
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            GW, data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"}), timeout=180)
        got = json.load(r).get("model")
    except Exception as e:
        got = "ERROR %s" % e
    ok = "ok  " if got == want else "FAIL"
    if got != want:
        fails += 1
    print("%s %-10s %-54s -> %s" % (ok, label, q[:52], got))

print()
if fails:
    print("%d of %d cases wrong" % (fails, len(CASES)))
    sys.exit(1)
print("all %d cases routed as expected" % len(CASES))
PY

echo
echo "gateway's own view (route= and endpoint= are the authoritative proof):"
kubectl logs -n agentgateway-system \
  -l gateway.networking.k8s.io/gateway-name=sovereign-gateway-internal --tail=7 \
  | grep -oE 'endpoint=[^ ]+|gen_ai.response.model=[^ ]+' | paste - - || true
