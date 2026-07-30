#!/usr/bin/env bash
# agentcore.sh — SOURCE it:  source scripts/agentcore.sh
#
# Kicks off the AWS Bedrock AgentCore deploy with a fast-returning cell so the
# notebook doesn't queue the kagent steps behind it:
#   • FOREGROUND (~30-60s): sign in to AWS + give the in-cluster registry the AWS
#     creds (aws-login.sh helm-upgrades it and waits for the rollout). This must
#     finish before §4, because §4 talks to the same registry server.
#   • BACKGROUND: the slow part — connect the aws-agentcore runtime if this is
#     the first run (04d: CloudFormation role + ECR + runtime registration), then
#     build + push to ECR + deploy (agentcore-deploy.sh). AgentCore provisions
#     (~2-4 min) while you carry on. It publishes its OWN agent record
#     (agentdemo-agentcore, ECR image), so it never races the kagent agentdemo.
#
# Watch the background deploy any time:  tail -f $AGENTCORE_LOG
# §9 (ac-invoke.sh) waits for the runtime to be READY, so just run it when you
# get there. Needs AWS_PROFILE + AGENT_GIT_URL (export them, or via SECRETS_FILE).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export AGENTCORE_LOG="${TMPDIR:-/tmp}/agentcore-deploy.log"
# Notebook bash kernels run with a minimal PATH; the backgrounded build needs
# docker/aws/gh/jq/arctl. Export a full PATH here so the detached child inherits it.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.arctl/bin:$PATH"

printf '→ Signing in to AWS and handing the registry the creds (foreground, ~30-60s)…\n'
# Source aws-login in a redirected group: the AWS_* env it exports still lands in
# THIS shell/kernel (ac-invoke reads it later); the noisy helm output goes to a log.
{ source "$SCRIPT_DIR/aws-login.sh"; } >"${AGENTCORE_LOG}.login" 2>&1
if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
  echo "  AWS sign-in failed — last lines of ${AGENTCORE_LOG}.login:"
  tail -15 "${AGENTCORE_LOG}.login"
  return 1 2>/dev/null || exit 1
fi
printf '✓ AWS ****%s / %s ready — in-cluster registry has the creds\n' \
  "${AWS_ACCOUNT_ID: -4}" "${AWS_REGION:-us-east-1}"

# Background the slow part: first-run runtime connect (idempotent, skipped when
# aws-agentcore already exists), then the per-agent build/push/deploy. AWS_* are
# exported above, so the detached process inherits the creds. 04d and
# agentcore-deploy each authenticate to the registry themselves (keychain login +
# a fresh minted token), so drop any stale kernel token before they start.
printf '→ Deploying to AgentCore in the BACKGROUND — carry on with §4.\n'
nohup bash -c "
  unset ARCTL_API_TOKEN
  if ! arctl get runtime aws-agentcore >/dev/null 2>&1; then
    echo '== first run: connecting the aws-agentcore runtime (04d) =='
    bash '$SCRIPT_DIR/04d-connect-aws.sh' || exit 1
  fi
  exec bash '$SCRIPT_DIR/agentcore-deploy.sh'
" >"$AGENTCORE_LOG" 2>&1 &
printf '   started (PID %s) · watch it: tail -f %s\n' "$!" "$AGENTCORE_LOG"
printf '   §9 (ac-invoke) waits for the runtime to be READY, so just run it when you get there.\n'
