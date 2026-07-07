#!/usr/bin/env bash
# create-agent-repo.sh — create the GitHub repo AWS Bedrock AgentCore clones the
# agent source from at deploy time, and push this demo's content into it.
#
# AgentCore builds the agent from source, so it needs a reachable git repo. This
# creates a PRIVATE repo by default and pushes the agentregistry-agentcore-kind
# folder to it (so AGENT_GIT_SUBFOLDER=artifacts/summarizer resolves). Requires
# the gh CLI, authenticated with `repo` scope.
#
#   ./scripts/create-agent-repo.sh                 # private repo, default name
#   REPO_VISIBILITY=public ./scripts/create-agent-repo.sh
#   AGENT_GIT_URL=https://github.com/<you>/<repo>.git ./scripts/create-agent-repo.sh
#
# Note: a PRIVATE repo means the AgentRegistry daemon needs a token to clone it.
# The notebook/08-agentcore.sh embed your `gh auth token` in the clone URL for
# that. A PUBLIC repo clones with no token (simplest); the agent code here is
# non-sensitive demo code, so public is a fine choice.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require gh; require git
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"

GH_USER="$(gh api user -q .login)"
BRANCH="${AGENT_GIT_BRANCH:-main}"
REPO_VISIBILITY="${REPO_VISIBILITY:-private}"
# Resolve owner/name from AGENT_GIT_URL if set, else default.
if [[ -n "${AGENT_GIT_URL:-}" ]]; then
  SLUG="${AGENT_GIT_URL#https://github.com/}"; SLUG="${SLUG%.git}"
else
  SLUG="${GH_USER}/agentregistry-agentcore-demo"
fi
URL="https://github.com/${SLUG}.git"

step "Repo ${SLUG} (${REPO_VISIBILITY})"
if gh repo view "$SLUG" >/dev/null 2>&1; then
  ok "repo already exists — will push current source to '${BRANCH}'"
else
  gh repo create "$SLUG" --"$REPO_VISIBILITY" \
    --description "AgentRegistry AgentCore demo — agent source (cloned by AgentCore at deploy)" >/dev/null
  ok "created ${SLUG}"
fi

step "Pushing the agent source"
TOK="$(gh auth token)"
TMP="$(mktemp -d)"
git -C "$TMP" init -q -b "$BRANCH"
# Copy the whole lab (project root: demo.ipynb + deploy/ + the scaffolded agentdemo/).
cp -R "$PROJECT_ROOT"/* "$TMP"/ 2>/dev/null || true
cp "$PROJECT_ROOT/.gitignore" "$TMP"/ 2>/dev/null || true
# drop the gitignored secrets/scratch (they live under deploy/ now).
rm -rf "$TMP/.agentcore" "$TMP/.env.local" "$TMP/deploy/.agentcore" "$TMP/deploy/.env.local"
git -C "$TMP" add -A
git -C "$TMP" -c user.email="${GIT_AUTHOR_EMAIL:-agentcore-demo@local}" -c user.name="${GIT_AUTHOR_NAME:-agentcore-demo}" \
  commit -q -m "agent source for AgentCore demo"
git -C "$TMP" remote add origin "https://x-access-token:${TOK}@github.com/${SLUG}.git"
git -C "$TMP" push -fq -u origin "$BRANCH" >/dev/null
rm -rf "$TMP"
ok "pushed to ${URL} (${BRANCH}); agent at subfolder artifacts/summarizer"

cat >&2 <<EOF

  Set in .env.local:
    export AGENT_GIT_URL="${URL}"
    export AGENT_GIT_BRANCH="${BRANCH}"
    export AGENT_GIT_SUBFOLDER="artifacts/summarizer"
EOF
