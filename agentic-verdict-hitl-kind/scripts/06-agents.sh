#!/usr/bin/env bash
# 06-agents.sh — THE DEVELOPER'S PHASE.
#
# A developer builds two SRE agents, publishes them to the AgentRegistry
# catalogue, and deploys them onto the kagent runtime. That is the whole job.
#
# Nothing in this phase knows about verdicts, approvals, gateways or Kyverno. Both
# agents are built from one template so they are byte-identical apart from their
# name, and both deployments ask for the same ungated MCP URL. Whatever differs
# between the two agents later was not done here.
#
# Re-runnable: arctl apply is idempotent, and `arctl build --push` re-pushes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets
[[ -n "${LB:-}" ]] || die "LB not set — run ./scripts/02-agentgateway.sh first"
cd "$LAB_ROOT"

# ── the two projects ──────────────────────────────────────────────────────────
# Committed in the repo, scaffolded once with the commands below. Re-rendered
# from the single template on every run so the two can never drift apart.
#
#   arctl init agent sretriage --framework adk --language python \
#       --model-provider anthropic --model-name claude-haiku-4-5
#   arctl init agent sreremediate  (same flags)
#
# Note the names have no hyphens: arctl rejects them. `arctl init agent` requires
# lowercase letters and digits only, so sre-triage is not a legal agent name.
step "Rendering both agents from artifacts/AGENT_TEMPLATE.py"
for a in "$GREEN_AGENT" "$RED_AGENT"; do
  [[ -f "$ARTIFACTS_DIR/$a/agent.yaml" ]] \
    || die "missing $ARTIFACTS_DIR/$a — re-scaffold with: arctl init agent $a --framework adk --language python --model-provider anthropic --model-name claude-haiku-4-5 --output-dir ./artifacts"
  sed "s/__NAME__/$a/g" "$ARTIFACTS_DIR/AGENT_TEMPLATE.py" > "$ARTIFACTS_DIR/$a/$a/agent.py"
  ok "rendered $a/agent.py"
done

# Prove the claim rather than asserting it. If these two ever diverge, the lab's
# central comparison ("same agent, different treatment") is no longer honest.
norm() { sed -e "s/$GREEN_AGENT/AGENT/g" -e "s/$RED_AGENT/AGENT/g" "$1"; }
if diff <(norm "$ARTIFACTS_DIR/$GREEN_AGENT/$GREEN_AGENT/agent.py") \
        <(norm "$ARTIFACTS_DIR/$RED_AGENT/$RED_AGENT/agent.py") >/dev/null; then
  ok "verified: the two agents are identical apart from their name"
else
  die "the two agent.py files differ beyond their name — the lab's premise is broken"
fi

# ── log in to the registry ────────────────────────────────────────────────────
step "Logging in to AgentRegistry as ${AS_USER}"
arctl_login && ok "logged in ($ARCTL_API_BASE_URL)"

# ── register the kagent runtime ───────────────────────────────────────────────
# type: Kagent — the in-cluster registry deploys through the kagent controller's
# HTTP API, forwarding the caller's bearer. No kubeconfig needed, unlike the
# local-daemon setup in agentregistry-arctl-kind.
step "Registering the kind-kagent runtime"
arctl apply -f - >/dev/null <<RT
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata: { name: kind-kagent }
spec:
  type: Kagent
  telemetryEndpoint: http://agentregistry-enterprise-telemetry-collector.${AR_NS}.svc.cluster.local:4318
  config: { kagentUrl: "http://kagent-controller.${KAGENT_NS}:8083", namespace: ${KAGENT_NS} }
RT
# The chart seeds two placeholder runtimes; drop them so `arctl get runtimes` is
# an honest list of one.
for r in virtual-default kubernetes-default; do
  arctl delete runtime "$r" >/dev/null 2>&1 || true
done
arctl get runtimes 2>/dev/null | sed 's/^/  /' >&2 || true
ok "runtime kind-kagent registered"

# ── build + publish ───────────────────────────────────────────────────────────
step "Building both agent images and pushing to localhost:${REG_PORT}"
for a in "$GREEN_AGENT" "$RED_AGENT"; do
  arctl build "$ARTIFACTS_DIR/$a" --push >/dev/null 2>&1 \
    && ok "built + pushed $a" \
    || die "arctl build failed for $a — is the kind-registry container running?"
done

# Evict the cached layer from every kind node, or the rebuild above is invisible.
#
# AgentRegistry deploys the agent with imagePullPolicy: IfNotPresent on a :latest
# tag, so a node that already holds :latest never pulls the new one. The pod comes
# up healthy running OLD code, and nothing anywhere reports a problem.
#
# This bit us for real: the green agent's image was left behind by a template
# change, and because a green agent's gating path is never exercised the drift
# stayed invisible until the register was switched to red: "*" — at which point the
# agent was correctly mutated, carried the right env var, and still did not gate,
# because its image predated the code that reads it.
step "Evicting the cached agent images from the kind nodes"
for n in $(kind get nodes --name "$CLUSTER_NAME" 2>/dev/null); do
  for a in "$GREEN_AGENT" "$RED_AGENT"; do
    docker exec "$n" crictl rmi "localhost:${REG_PORT}/${a}:latest" >/dev/null 2>&1 || true
  done
done
ok "nodes will pull the images just pushed"

step "Publishing both agents to the catalogue"
for a in "$GREEN_AGENT" "$RED_AGENT"; do
  arctl apply -f "$ARTIFACTS_DIR/$a/agent.yaml" >/dev/null 2>&1 \
    && ok "published $a" || die "arctl apply failed for $a"
done
arctl get agents 2>/dev/null | sed 's/^/  /' >&2 || true

# ── deploy ────────────────────────────────────────────────────────────────────
step "Deploying both agents onto the kagent runtime"
sed "s/__LB__/${LB}/g" "$LAB_ROOT/yaml/agents/deployments.yaml" \
  | arctl apply -f - >/dev/null 2>&1 \
  && ok "both deployments applied" || die "arctl apply of the deployments failed"

# ── the third agent: same job, written the kagent-native way ──────────────────
# A Declarative agent instead of a BYO container. Still an ADK agent
# (declarative.runtime: python), but because kagent can see its tool list, kagent's
# own approval flow becomes available — which is the surface most people should
# actually use. Applied with kubectl rather than through AgentRegistry because a
# declarative agent has no image to publish.
#
# The developer's file contains NO requireApproval. Phase 07 adds it.
step "Deploying the declarative (kagent-native) variant"
kc apply -f "$LAB_ROOT/yaml/agents/declarative-native.yaml" >/dev/null
ok "RemoteMCPServer + Agent/srenative applied"

step "Waiting for the agents to reconcile onto kagent"
for a in "$GREEN_AGENT" "$RED_AGENT" "$NATIVE_AGENT"; do
  end=$(( $(date +%s) + 300 ))
  cr=""
  until cr="$(kc -n "$KAGENT_NS" get agents.kagent.dev -o name 2>/dev/null \
              | sed 's#.*/##' | grep -i "^${a}" | head -1)"; [[ -n "$cr" ]]; do
    [[ $(date +%s) -ge $end ]] && break
    sleep 5
  done
  if [[ -n "$cr" ]]; then
    kc -n "$KAGENT_NS" rollout status "deploy/$cr" --timeout=300s >/dev/null 2>&1 \
      && ok "$cr Ready" || warn "$cr not Ready yet"
  else
    warn "no kagent Agent for $a yet — check: kubectl --context $CTX -n $KAGENT_NS get agent"
  fi
done

# ── the premise, checked on the RUNNING pods ──────────────────────────────────
# 06 already diffs the two rendered sources, which catches drift in the repo. It
# cannot catch a stale image, and a stale image breaks the lab in the most
# misleading way available: the policy mutates correctly, the env var is present,
# and the agent still does not gate. So assert on what is actually running.
# Evicting the layer is not enough on its own: the Deployment spec has not changed,
# so nothing creates a new pod and the old one keeps running. Restart it explicitly,
# which is what makes the node pull the image pushed above.
step "Restarting both agents so the nodes pull the fresh image"
for a in "$GREEN_AGENT" "$RED_AGENT"; do
  kc -n "$KAGENT_NS" rollout restart "deploy/$a" >/dev/null 2>&1 || true
done
for a in "$GREEN_AGENT" "$RED_AGENT"; do
  kc -n "$KAGENT_NS" rollout status "deploy/$a" --timeout=300s >/dev/null 2>&1 \
    && ok "$a restarted on the new image" || warn "$a did not report a completed rollout"
done

step "Confirming both pods run the agent code just built"
for a in "$GREEN_AGENT" "$RED_AGENT"; do
  # Exact comparison, not a heuristic: the file in the pod must be the file this
  # phase rendered and built. A count of some marker string would drift the moment
  # the template changes shape.
  if kc -n "$KAGENT_NS" exec "deploy/$a" -- cat "/app/$a/agent.py" 2>/dev/null \
       | diff -q - "$ARTIFACTS_DIR/$a/$a/agent.py" >/dev/null 2>&1; then
    ok "$a is running exactly the code just built"
  else
    warn "$a is running DIFFERENT code from the image just built — stale layer"
    warn "  for n in \$(kind get nodes --name $CLUSTER_NAME); do"
    warn "    docker exec \$n crictl rmi localhost:${REG_PORT}/${a}:latest; done"
    warn "  kubectl -n $KAGENT_NS rollout restart deploy/$a"
  fi
done

# ── show that both are wired identically, right now ───────────────────────────
# This is the "before" half of the lab's central comparison. At this point both
# pods point at /mcp. Phase 07 stamps the verdict and re-checks.
step "MCP wiring as deployed (both should read /mcp)"
for a in "$GREEN_AGENT" "$RED_AGENT"; do
  url="$(kc -n "$KAGENT_NS" get agent "$a" \
        -o jsonpath='{.spec.byo.deployment.env[?(@.name=="MCP_SERVERS_CONFIG")].value}' 2>/dev/null \
        | python3 -c 'import sys,json; d=sys.stdin.read().strip(); print(json.loads(d)[0]["url"] if d else "(unset)")' 2>/dev/null || echo "(unreadable)")"
  log "$(printf '%-14s %s' "$a" "$url")"
done

step "Both agents deployed"
cat >&2 <<EOF

  Two agents, same code, same tools, same route. Nothing is gated yet.

  Talk to them:  ./scripts/ask.sh ${GREEN_AGENT} "which pods are unhealthy in shop?"
  Next:          ./scripts/07-verdict.sh   (the external review lands)
EOF
