#!/usr/bin/env bash
# What the lab needs before anything is applied.
#
#   ./scripts/00-check.sh
#
# Tools, an AWS identity, the model-routing lab's manifests next door, and the two
# frontier provider keys in the environment. Nothing here changes anything.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -uo pipefail
fail=0
ok()   { printf "  ok    %s\n" "$*"; }
bad()  { printf "  FAIL  %s\n" "$*"; fail=1; }
for t in aws eksctl kubectl helm openssl python3 curl; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t not on PATH"; fi
done
acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [ -n "$acct" ] && [ "$acct" != "None" ]; then ok "AWS identity (account ending ${acct: -4})"; else bad "no AWS identity: set AWS_PROFILE or run aws sso login"; fi
PART1_DIR="$(cd "${PART1_DIR:-$HERE/../agentgateway-inference-model-routing-eks}" 2>/dev/null && pwd || true)"
if [ -f "$PART1_DIR/yaml/00-mistral-model.yaml" ]; then ok "Part 1 manifests at $PART1_DIR"; else bad "cannot find the model-routing lab; set PART1_DIR"; fi
if [ -n "${OPENAI_API_KEY:-}" ]; then ok "OPENAI_API_KEY set"; else bad "OPENAI_API_KEY not set (export it, or source your secrets file)"; fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then ok "ANTHROPIC_API_KEY set"; else bad "ANTHROPIC_API_KEY not set"; fi
EKS_CLUSTER="${EKS_CLUSTER:-model-routing}"; AWS_REGION="${AWS_REGION:-eu-west-2}"
if aws eks describe-cluster --region "$AWS_REGION" --name "$EKS_CLUSTER" >/dev/null 2>&1; then
  ok "cluster $EKS_CLUSTER exists (01-cluster.sh will reuse it)"
else
  echo "  note  cluster $EKS_CLUSTER does not exist; 01-cluster.sh creates it with one GPU node, about \$5.85/hr while up"
fi
echo
if [ "$fail" = 0 ]; then echo "Ready. Next: ./scripts/01-cluster.sh"; else echo "Fix the FAIL lines above."; exit 1; fi
