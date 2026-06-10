#!/usr/bin/env bash
# 05-equip-sandbox.sh — make the OpenClaw sandbox able to act as an SRE.
#
# After the harness is Ready, the sandbox is a bare OpenClaw VM: no kubectl, no
# kubeconfig, and OpenClaw's model key is a gateway-only placeholder. This step
# closes those three gaps so an operator can attach and ask OpenClaw to triage
# and fix the cluster:
#
#   1. kubectl — downloaded into the sandbox (arch-detected).
#   2. kubeconfig — points at the in-cluster API, authenticating as the sandbox
#      ServiceAccount (which 04-harness.sh granted cluster read + incident write).
#   3. model key — kagent writes openclaw.json with apiKey set to the placeholder
#      "openshell:resolve:env:ANTHROPIC_API_KEY" (resolved only by the OpenShell
#      gateway path). For the scriptable embedded driver (openclaw agent --local)
#      we materialize the real key into the config. See CLAUDE.md for the why.
#
# It also installs an `sre-agent` helper inside the sandbox so the demo is a
# one-liner: `sre-agent "fix the incident namespace"`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_secrets

step "Locating the sandbox"
read -r SB_NS SB_POD SB_SA < <(find_sandbox || true)
[[ -n "${SB_POD:-}" ]] || die "could not find the sandbox pod — is the harness Ready? (kubectl -n kagent get agentharness)"
ok "sandbox ${SB_NS}/${SB_POD} (sa: ${SB_SA})"

ex()  { kc -n "$SB_NS" exec "$SB_POD" -c agent -- "$@"; }       # as root
exi() { kc -n "$SB_NS" exec -i "$SB_POD" -c agent -- "$@"; }    # as root, stdin
sbx() { kc -n "$SB_NS" exec "$SB_POD" -c agent -- su sandbox -c "$1"; }
sbxi(){ kc -n "$SB_NS" exec -i "$SB_POD" -c agent -- su sandbox -c "$1"; }

# ── 1. kubectl ────────────────────────────────────────────────────────────────
step "Installing kubectl into the sandbox"
ex sh -c 'command -v kubectl >/dev/null 2>&1 && { echo present; exit 0; }
  ARCH=$(uname -m); case "$ARCH" in aarch64|arm64) A=arm64;; *) A=amd64;; esac
  V=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -sLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${V}/bin/linux/${A}/kubectl"
  chmod +x /usr/local/bin/kubectl
  echo "installed ${V} ${A}"' >/dev/null
ok "kubectl available in the sandbox"

# ── 2. kubeconfig (authenticate as the sandbox ServiceAccount) ────────────────
step "Writing a kubeconfig for the sandbox ServiceAccount"
TOKEN="$(kc -n "$SB_NS" create token "$SB_SA" --duration=24h 2>/dev/null || kc -n "$SB_NS" create token "$SB_SA")"
[[ -n "$TOKEN" ]] || die "failed to mint a token for ${SB_NS}/${SB_SA}"
printf '%s' "$TOKEN" | sbxi 'read TK
  mkdir -p /sandbox/.kube
  kubectl config set-cluster kind --server=https://kubernetes.default.svc --insecure-skip-tls-verify=true >/dev/null
  kubectl config set-credentials sa --token="$TK" >/dev/null
  kubectl config set-context c --cluster=kind --user=sa >/dev/null
  kubectl config use-context c >/dev/null
  echo ok' >/dev/null
ok "kubeconfig written (24h token; re-run this script to refresh)"

# ── 3. materialize the model key + install the sre-agent helper ───────────────
step "Materializing the model key for the embedded driver"
KEY="$(kc -n kagent get secret kagent-anthropic -o jsonpath='{.data.ANTHROPIC_API_KEY}' | base64 -d)"
[[ -n "$KEY" ]] || die "kagent-anthropic secret not found"

# Key-setter used by the sre-agent wrapper (re-asserts the key each run, so a
# gateway config-rewrite can never leave a stale placeholder behind).
exi sh -c 'cat > /usr/local/bin/_sre_setkey.py && chmod +x /usr/local/bin/_sre_setkey.py' <<'PY'
import json, sys
p = "/sandbox/.openclaw/openclaw.json"
d = json.load(open(p))
d["models"]["providers"]["anthropic"]["apiKey"] = sys.argv[1]
json.dump(d, open(p, "w"), indent=2)
PY

# The one-liner the demo uses. Re-asserts the key, then runs one embedded
# OpenClaw agent turn with the operator's prompt.
exi sh -c 'cat > /usr/local/bin/sre-agent && chmod +x /usr/local/bin/sre-agent' <<'SH'
#!/bin/sh
# sre-agent "<what you want OpenClaw to do>"
[ -f /sandbox/.anthropic-key ] && python3 /usr/local/bin/_sre_setkey.py "$(cat /sandbox/.anthropic-key)" 2>/dev/null
cd /sandbox
exec openclaw agent --local --session-id sre -m "$*"
SH

printf '%s' "$KEY" | sbxi 'read K; umask 077; printf "%s" "$K" > /sandbox/.anthropic-key; python3 /usr/local/bin/_sre_setkey.py "$K"; echo ok' >/dev/null
ok "model key materialized + sre-agent helper installed"

# ── optional: Slack webhook for the escalate-when-denied path ─────────────────
step "Slack escalation webhook"
if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
  printf '%s' "$SLACK_WEBHOOK_URL" | sbxi 'read W; umask 077; printf "%s" "$W" > /sandbox/.slack-webhook; echo ok' >/dev/null
  ok "webhook written to /sandbox/.slack-webhook (agent posts here when denied a fix)"
else
  # Remove any stale webhook so the agent doesn't post to an old URL.
  sbx 'rm -f /sandbox/.slack-webhook' >/dev/null 2>&1 || true
  warn "SLACK_WEBHOOK_URL not set — the agent will report escalations in its reply instead of Slack"
fi

# ── verify ────────────────────────────────────────────────────────────────────
step "Verifying the sandbox can reach the model and the cluster"
log "model turn (expect PONG)..."
PONG="$(sbx 'cd /sandbox && timeout 90 openclaw agent --local --session-id check -m "Reply with exactly the single word: PONG"' 2>/dev/null | tr -d "[:space:]" | grep -o PONG | head -1 || true)"
[[ "$PONG" == "PONG" ]] && ok "model reachable (Anthropic)" || warn "model turn did not return PONG — check the Anthropic key / egress"
log "cluster read (sandbox kubectl)..."
sbx 'kubectl get ns >/dev/null 2>&1 && echo ok' >/dev/null 2>&1 && ok "sandbox kubectl can read the cluster" || warn "sandbox kubectl could not reach the API"

step "Sandbox equipped"
echo "  Ask OpenClaw to triage from your shell:" >&2
echo "    kubectl --context $CTX -n $SB_NS exec -it $SB_POD -c agent -- su sandbox -c 'sre-agent \"what is broken in the incident namespace?\"'" >&2
echo "  Or use the helper:  ./scripts/ask.sh \"fix the incident namespace\"" >&2
echo "  Next:               ./scripts/06-broken-app.sh" >&2
