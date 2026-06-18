#!/usr/bin/env bash
# push-source.sh — push the scaffolded agent's SOURCE to its git repo. The
# published registry entry references this repo, and AWS Bedrock AgentCore
# clones it at deploy time. (kagent runs from the image and doesn't need this,
# but publishing the source is part of the "publish to the registry" story.)
#
# Repo comes from AGENT_GIT_URL / AGENT_GIT_BRANCH in .env.local
# (./scripts/setup-env.sh sets these; create-agent-repo.sh can make one).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_secrets

PROJ="${1:-$LAB_ROOT/agentdemo}"
[[ -d "$PROJ" ]] || die "agent project not found at $PROJ — scaffold it first"
: "${AGENT_GIT_URL:?set AGENT_GIT_URL in .env.local (./scripts/setup-env.sh)}"

BR="${AGENT_GIT_BRANCH:-main}"
SLUG="${AGENT_GIT_URL#https://github.com/}"; SLUG="${SLUG%.git}"
PUSH_URL="$AGENT_GIT_URL"
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && PUSH_URL="https://x-access-token:$(gh auth token)@github.com/${SLUG}.git"

step "Pushing the agent source to $SLUG@$BR"
T="$(mktemp -d)"; cp -R "$PROJ/." "$T/"; rm -rf "$T/.git" "$T/.venv"
( cd "$T" && git init -qb "$BR" && git add -A \
  && git -c user.email=demo@local -c user.name=demo commit -qm "agentdemo source" \
  && git remote add origin "$PUSH_URL" && git push -fq origin "$BR" ) \
  && ok "pushed source to $SLUG@$BR" || die "git push failed"
rm -rf "$T"
