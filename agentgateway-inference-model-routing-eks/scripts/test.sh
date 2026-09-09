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

# Piped over stdin rather than staged with `kubectl cp`. cp into this pod fails and,
# under `set -e`, takes the whole script down without printing anything at all, which
# reads as "the test produced no output" rather than as an error.
kubectl exec -i -n models "$POD" -- python3 - <<'PY'
import json, sys, urllib.request

GW = ("http://model-gateway.agentgateway-system.svc.cluster.local"
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
  -l gateway.networking.k8s.io/gateway-name=model-gateway --tail=7 \
  | grep -oE 'endpoint=[^ ]+|gen_ai.response.model=[^ ]+' | paste - - || true
