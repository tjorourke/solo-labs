#!/usr/bin/env bash
# agentcore.sh — SOURCE it:  source scripts/agentcore.sh
#
# Kicks off the AWS Bedrock AgentCore deploy with a fast-returning cell so the
# notebook doesn't queue your other steps:
#   • FOREGROUND (~30-45s): sign in to AWS + re-launch the registry daemon with
#     AWS creds, behind Keycloak. This must finish before §6, because §6 talks to
#     the same daemon — you don't want it mid-restart while you run kagent steps.
#   • BACKGROUND: the slow part — docker build + push to ECR + deploy. It runs
#     detached and AgentCore provisions (~2-4 min) while you do §6. AgentCore
#     publishes its OWN agent record (agentdemo-agentcore, ECR image), so it never
#     races the kagent agentdemo agent. §8 (ac-invoke) waits for READY.
#
# Watch the background deploy any time:  tail -f $AGENTCORE_LOG
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export AGENTCORE_LOG="${TMPDIR:-/tmp}/agentcore-deploy.log"
# Notebook bash kernels run with a minimal PATH; the backgrounded build needs
# docker/aws/gh/jq/arctl. Export a full PATH here so the detached child inherits it.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.arctl/bin:$PATH"

printf '→ Signing in to AWS and preparing the daemon (foreground, ~30-45s)…\n'
# Source aws-login in a redirected group: the AWS_* env it exports still lands in
# THIS shell; the noisy daemon-restart output goes to a log.
{ source "$SCRIPT_DIR/aws-login.sh"; } >"${AGENTCORE_LOG}.login" 2>&1
# aws-login establishes AWS creds but NOT the registry bearer. In a fresh notebook
# kernel (where only connect.sh ran) ARCTL_API_TOKEN is unset — only setup-time
# 04d-connect-aws.sh exports it. Mint it here the same way (lib.sh's arctl_token),
# in a subshell so lib.sh's `set -e` can't kill this sourced script.
if [ -z "${ARCTL_API_TOKEN:-}" ] || [ "${ARCTL_API_TOKEN}" = "null" ]; then
  export ARCTL_API_TOKEN="$(source "$SCRIPT_DIR/lib.sh" >/dev/null 2>&1; arctl_token 2>/dev/null)"
fi
if [ -z "${AWS_ACCOUNT_ID:-}" ] || [ -z "${ARCTL_API_TOKEN:-}" ] || [ "${ARCTL_API_TOKEN}" = "null" ]; then
  echo "  AWS / daemon preparation failed — last lines of ${AGENTCORE_LOG}.login:"
  tail -25 "${AGENTCORE_LOG}.login"
  return 1 2>/dev/null || exit 1
fi
printf '✓ AWS ****%s / %s ready — daemon behind Keycloak with AWS creds\n' \
  "${AWS_ACCOUNT_ID: -4}" "${AWS_REGION:-us-east-1}"

# Background the slow build/push/deploy. AWS_* are exported above, so the detached
# process inherits the creds. nohup + & so the notebook cell returns immediately.
printf '→ Building + deploying to AgentCore in the BACKGROUND — carry on with §6.\n'
nohup bash "$SCRIPT_DIR/agentcore-deploy.sh" >"$AGENTCORE_LOG" 2>&1 &
printf '   started (PID %s) · watch it: tail -f %s\n' "$!" "$AGENTCORE_LOG"
printf '   §8 (ac-invoke) waits for the runtime to be READY, so just run it when you get there.\n'
