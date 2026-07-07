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
cd "$PROJECT_ROOT"   # the scaffolded agentdemo/ lives at the lab root, not under deploy/

# Notebook bash kernels often run with a minimal PATH (no Homebrew), so make sure
# the tools this script needs are reachable even when launched from a cell.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.arctl/bin:$PATH"

: "${AGENT_GIT_URL:?set AGENT_GIT_URL in .env.local}"
[[ -d agentdemo ]] || die "no agentdemo/ here — scaffold it first (arctl init agent agentdemo ...)"
command -v gh  >/dev/null 2>&1 || die "gh CLI not found on PATH. PATH=$PATH"
command -v git >/dev/null 2>&1 || die "git not found on PATH. PATH=$PATH"

SLUG="${AGENT_GIT_URL#https://github.com/}"; SLUG="${SLUG%.git}"; BR="${AGENT_GIT_BRANCH:-main}"
# gh's token may live in the macOS keychain, which a notebook-kernel process can't
# always read. Fail with a clear message instead of pushing with an empty token.
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-$(gh auth token 2>/dev/null)}}"
[[ -n "$TOKEN" ]] || die "no GitHub token available in this shell. From a cell, gh can't always read the keychain — run \`gh auth token\` in a terminal to confirm, then either run this script from a terminal, or export GH_TOKEN before launching the notebook."
PUSH_URL="https://x-access-token:${TOKEN}@github.com/${SLUG}.git"
T="$(mktemp -d)"; cp -R agentdemo "$T/agentdemo"; rm -rf "$T/agentdemo/.git" "$T/agentdemo/.venv"
( cd "$T" \
  && git init -qb "$BR" && git add -A \
  && git -c user.email=demo@local -c user.name=demo commit -qm "agentdemo source" \
  && git remote add origin "$PUSH_URL" && git push -fq origin "$BR" )
rm -rf "$T"
ok "pushed agentdemo/ source -> ${SLUG}@${BR}"
