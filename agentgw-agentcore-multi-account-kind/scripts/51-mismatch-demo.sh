#!/usr/bin/env bash
# 51-mismatch-demo.sh — the live proof of WHY this lab hand-writes its gateway
# backends: bind both Runtimes (two AWS accounts) to one registry-managed
# Gateway and watch the reconciler refuse with AWSAccountMismatch (one IRSA
# role per ServiceAccount = one account per automated binding). Fully
# reversible: `./scripts/51-mismatch-demo.sh revert` restores the unbound
# Runtimes, and the hand-written backends keep serving throughout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_tofu_env
arctl_login

apply_runtime() { # apply_runtime <env> <role> <extid> <region> [gatewayRef]
  local env="$1" role="$2" extid="$3" region="$4" gwref="${5:-}"
  local F; F="$(mktemp)"
  { echo "apiVersion: ar.dev/v1alpha1"
    echo "kind: Runtime"
    echo "metadata: {name: ${env}}"
    echo "spec:"
    echo "  type: BedrockAgentCore"
    echo "  telemetryEndpoint: ${AR_TELEMETRY_ENDPOINT}"
    echo "  config:"
    echo "    roleArn: \"${role}\""
    echo "    externalId: \"${extid}\""
    echo "    region: \"${region}\""
    [[ -n "$gwref" ]] && echo "    gatewayRef: {name: ${gwref}}"
  } > "$F"
  arctl apply -f "$F" >/dev/null; rm -f "$F"
}

if [[ "${1:-}" == "revert" ]]; then
  step "Reverting: removing gatewayRef from both Runtimes and deleting the AR Gateway"
  apply_runtime portfolio-a "$PORTFOLIO_A_AR_ROLE_ARN" "$PORTFOLIO_A_EXTERNAL_ID" "$PORTFOLIO_A_REGION"
  apply_runtime portfolio-b "$PORTFOLIO_B_AR_ROLE_ARN" "$PORTFOLIO_B_EXTERNAL_ID" "$PORTFOLIO_B_REGION"
  arctl delete gateway one-gateway-for-everything >/dev/null 2>&1 || true
  ok "reverted — Runtimes unbound, registry Gateway removed"
  exit 0
fi

step "One-time prerequisite: outbound web identity federation in both accounts"
# The 2026.8 reconciler resolves each bound runtime's outbound identity before
# the account check; a fresh account 404s on GetOutboundWebIdentityFederationInfo
# until the feature is enabled. Idempotent; runs under each AgentRegistryAccess
# role (tofu grants iam:EnableOutboundWebIdentityFederation).
enable_fed() { # enable_fed <role-arn> <external-id>
  ( out="$(AWS_ACCESS_KEY_ID="$AR_AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AR_AWS_SECRET_ACCESS_KEY" AWS_SESSION_TOKEN= \
      aws sts assume-role --role-arn "$1" --external-id "$2" \
      --role-session-name enable-fed --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)" || exit 1
    export AWS_ACCESS_KEY_ID="$(awk '{print $1}' <<<"$out")" AWS_SECRET_ACCESS_KEY="$(awk '{print $2}' <<<"$out")" AWS_SESSION_TOKEN="$(awk '{print $3}' <<<"$out")"
    # Guard against credential fallthrough: act only in the expected account.
    [[ "$(aws sts get-caller-identity --query Account --output text)" == "$(cut -d: -f5 <<<"$1")" ]] || exit 1
    aws iam get-outbound-web-identity-federation-info >/dev/null 2>&1 \
      || aws iam enable-outbound-web-identity-federation >/dev/null 2>&1 || true )
}
enable_fed "$PORTFOLIO_A_AR_ROLE_ARN" "$PORTFOLIO_A_EXTERNAL_ID" && ok "portfolio-a federation enabled"
enable_fed "$PORTFOLIO_B_AR_ROLE_ARN" "$PORTFOLIO_B_EXTERNAL_ID" && ok "portfolio-b federation enabled"

step "Applying a registry-managed Gateway (Kubernetes platform)"
F="$(mktemp)"; cat > "$F" <<EOF
apiVersion: ar.dev/v1alpha1
kind: Gateway
metadata: {name: one-gateway-for-everything}
spec:
  kubernetes: {gatewayClass: enterprise-agentgateway}
EOF
arctl apply -f "$F"; rm -f "$F"

step "Binding BOTH Runtimes (two AWS accounts) to it via gatewayRef"
apply_runtime portfolio-a "$PORTFOLIO_A_AR_ROLE_ARN" "$PORTFOLIO_A_EXTERNAL_ID" "$PORTFOLIO_A_REGION" one-gateway-for-everything
apply_runtime portfolio-b "$PORTFOLIO_B_AR_ROLE_ARN" "$PORTFOLIO_B_EXTERNAL_ID" "$PORTFOLIO_B_REGION" one-gateway-for-everything
ok "both Runtimes bound"

step "Watching the reconciler refuse (multiple AWS accounts behind one binding)"
# On this build (AR 2026.8.0) the refusal surfaces in the reconciler log
# (component gateway-irsa); newer builds also stamp a GatewayIdentityReady=
# False / AWSAccountMismatch status condition. Check both. Prerequisite for
# the reconciler to get this far on a fresh account pair: outbound web
# identity federation enabled once per account
# (aws iam enable-outbound-web-identity-federation, under the
# AgentRegistryAccess role — tofu grants the action).
FOUND=""
for _ in $(seq 1 30); do
  OUT="$(arctl get gateway one-gateway-for-everything -o yaml 2>/dev/null || true)"
  LOGLINE="$(kc -n "$AR_NS" logs deploy/"$AR_SERVER_SVC" --since=3m 2>/dev/null | grep -i "multiple AWS accounts" | tail -1 || true)"
  if grep -qi "AWSAccountMismatch\|multiple AWS accounts" <<<"$OUT" || [[ -n "$LOGLINE" ]]; then FOUND=1; break; fi
  sleep 10
done
if [[ -n "$FOUND" ]]; then
  [[ -n "$LOGLINE" ]] && printf '%s\n' "$LOGLINE" | jq -r '"  \(.component): \(.msg): \(.error // "")"' 2>/dev/null >&2
  grep -iE "type:|status:|reason:|message:|phase:" <<<"$OUT" | sed 's/^/  /' >&2
  ok "refused as designed: one automated binding covers one AWS account"
else
  warn "refusal not observed within 5m — full status follows"
  arctl get gateway one-gateway-for-everything -o yaml 2>/dev/null | sed 's/^/  /' >&2
fi

step "Run './scripts/51-mismatch-demo.sh revert' to restore the unbound Runtimes"
