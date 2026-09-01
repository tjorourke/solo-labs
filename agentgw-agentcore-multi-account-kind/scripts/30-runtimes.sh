#!/usr/bin/env bash
# 30-runtimes.sh — register the two portfolio accounts as BedrockAgentCore
# Runtimes. Each carries that account's AgentRegistryAccess role + ExternalId
# (from tofu) and DELIBERATELY no config.gatewayRef: without a gatewayRef the
# registry never renders gateway backends or writes gateway IAM, which is the
# whole point of this lab's hand-written single-gateway shape.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_secrets
load_tofu_env
arctl_login

step "Registering Runtime portfolio-a (${PORTFOLIO_A_REGION})"
RT="$(mktemp)"; cat > "$RT" <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata: {name: portfolio-a}
spec:
  type: BedrockAgentCore
  telemetryEndpoint: ${AR_TELEMETRY_ENDPOINT}
  config:
    roleArn: "${PORTFOLIO_A_AR_ROLE_ARN}"
    externalId: "${PORTFOLIO_A_EXTERNAL_ID}"
    region: "${PORTFOLIO_A_REGION}"
EOF
arctl apply -f "$RT"; rm -f "$RT"

step "Registering Runtime portfolio-b (${PORTFOLIO_B_REGION})"
RT="$(mktemp)"; cat > "$RT" <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata: {name: portfolio-b}
spec:
  type: BedrockAgentCore
  telemetryEndpoint: ${AR_TELEMETRY_ENDPOINT}
  config:
    roleArn: "${PORTFOLIO_B_AR_ROLE_ARN}"
    externalId: "${PORTFOLIO_B_EXTERNAL_ID}"
    region: "${PORTFOLIO_B_REGION}"
EOF
arctl apply -f "$RT"; rm -f "$RT"

step "Runtimes registered"
arctl get runtimes 2>/dev/null | sed 's/^/  /' >&2 || true
echo "  Next: ./scripts/31-agents.sh" >&2
