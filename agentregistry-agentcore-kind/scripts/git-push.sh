#!/usr/bin/env bash
# git-push.sh — push the scaffolded agentdemo/ SOURCE to your agent git repo.
# AWS Bedrock AgentCore clones the agent source from git at deploy time, so the
# source must live in a repo it can reach. Repo + branch come from .env.local
# (AGENT_GIT_URL, optional AGENT_GIT_BRANCH); auth uses your gh CLI token.
#
#   ./scripts/git-push.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_secrets
cd "$LAB_ROOT"

: "${AGENT_GIT_URL:?set AGENT_GIT_URL in .env.local}"
[[ -d agentdemo ]] || die "no agentdemo/ here — scaffold it first (arctl init agent agentdemo ...)"

SLUG="${AGENT_GIT_URL#https://github.com/}"; SLUG="${SLUG%.git}"; BR="${AGENT_GIT_BRANCH:-main}"
PUSH_URL="https://x-access-token:$(gh auth token)@github.com/${SLUG}.git"
T="$(mktemp -d)"; cp -R agentdemo "$T/agentdemo"; rm -rf "$T/agentdemo/.git" "$T/agentdemo/.venv"
( cd "$T" \
  && git init -qb "$BR" && git add -A \
  && git -c user.email=demo@local -c user.name=demo commit -qm "agentdemo source" \
  && git remote add origin "$PUSH_URL" && git push -fq origin "$BR" )
rm -rf "$T"
ok "pushed agentdemo/ source -> ${SLUG}@${BR}"
