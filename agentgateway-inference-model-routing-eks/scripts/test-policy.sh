#!/usr/bin/env bash
# Run the entitlement matrix through the gateway with OPA deciding.
#
#   ./scripts/test-policy.sh
#
# Eight requests, from inside the cluster like test-classifiers.sh: two teams, "auto"
# against a named model, a prompt in both content shapes, and one request that has to
# be refused. Each row prints what OPA decided (the x-opa-decision response header)
# and which model actually answered, read from the response body. The two agreeing is
# the path: extAuth at PreRouting, the x-model header, the route match, the rewrite.
#
# Assumes ./scripts/06-opa.sh has been applied. On the keyword or semantic policy
# every row still answers, with no x-opa-decision and no 403, and the script says so.
set -euo pipefail

# The lab root, so the script works from anywhere.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

. "$HERE/scripts/lib-context.sh"
resolve_ctx
kubectl() { command kubectl --context "$CTX" "$@"; }

# 2>/dev/null because kubectl prints a jsonpath template dump when the list is empty,
# which buries the real problem: you are pointed at the wrong cluster.
POD="$(kubectl get pod -n models -l app=vllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$POD" ]; then
  echo "error: no pod matching -l app=vllm in namespace 'models'." >&2
  echo "  context in use: $CTX" >&2
  echo "  set another with KUBE_CONTEXT=<name>, or EKS_CLUSTER=<cluster> for an EKS ARN." >&2
  exit 1
fi
PHASE="$(kubectl get pod -n models "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [ "$PHASE" != "Running" ]; then
  echo "error: pod $POD is $PHASE, not Running. Both models must be serving." >&2
  echo "  if the GPU nodes are scaled to zero:  ./scripts/gpu.sh up" >&2
  exit 1
fi

# Either edition's kind: the OSS AgentgatewayPolicy or the EnterpriseAgentgatewayPolicy.
DECIDER="$(kubectl -n agentgateway-system get agentgatewaypolicy,enterpriseagentgatewaypolicy extract-model-internal \
  -o jsonpath='{range .items[*]}{.spec.traffic.extAuth.backendRef.name}{end}' 2>/dev/null || true)"
if [ "$DECIDER" != "opa" ]; then
  echo "note: the policy is not calling OPA (extAuth.backendRef is '${DECIDER:-unset}')." >&2
  echo "      apply it first:  ./scripts/06-opa.sh" >&2
fi

kubectl exec -i -n models "$POD" -- python3 - <<'PY'
import json, urllib.request, urllib.error
GW = "http://model-gateway.agentgateway-system.svc.cluster.local/v1/chat/completions"
MISTRAL, QWEN = "mistral-small-3.2-24b", "qwen3-coder-30b"
CODE = "Write a Python function that reverses a linked list."
FIN  = "What is IFRS 9 stage 2 impairment?"
PARTS = [{"type": "text", "text": "Refactor this Python function to avoid the inner loop."}]

# team, model asked for, content, what should happen
CASES = [
    ("platform", "auto",  CODE,  QWEN,    "entitled to both, classified as code"),
    ("platform", "auto",  FIN,   MISTRAL, "entitled to both, classified as general"),
    ("finance",  "auto",  CODE,  MISTRAL, "a code prompt, held to the finance entitlement"),
    ("finance",  QWEN,    CODE,  "403",   "named a model the team may not use"),
    ("finance",  MISTRAL, FIN,   MISTRAL, "named a model the team may use"),
    ("platform", QWEN,    "anything", QWEN, "named a model the team may use"),
    (None,       "auto",  CODE,  MISTRAL, "no team, so the default entitlement"),
    ("platform", "auto",  PARTS, QWEN,    "list content, as an agent sends it"),
]

def call(team, model, content):
    body = {"model": model, "max_tokens": 6,
            "messages": [{"role": "user", "content": content}]}
    hdr = {"Content-Type": "application/json"}
    if team:
        hdr["x-team"] = team
    req = urllib.request.Request(GW, data=json.dumps(body).encode(), headers=hdr)
    try:
        r = urllib.request.urlopen(req, timeout=180)
        return r.status, r.headers.get("x-opa-decision", "-"), json.load(r).get("model", "?")
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("x-opa-decision", "-"), str(e.code)
    except Exception as e:
        return 0, "-", "ERROR %s" % e

ok = 0
print(f"{'TEAM':9} {'ASKED FOR':22} {'PROMPT':38} {'EXPECT':22} {'OPA':22} {'ANSWERED':22}")
for team, model, content, want, why in CASES:
    status, decided, answered = call(team, model, content)
    shown = content if isinstance(content, str) else "[parts] " + content[0]["text"]
    good = answered == want
    ok += good
    mark = "ok " if good else "X  "
    print(f"{team or '(none)':9} {model:22} {shown[:38]:38} {want:22} {decided:22} {mark}{answered}")
print()
print(f"policy decisions: {ok}/{len(CASES)} as expected")
raise SystemExit(0 if ok == len(CASES) else 1)
PY
