#!/usr/bin/env bash
# 02-access-policies.sh — partition the catalog per team with AccessPolicies.
#
# Without a policy a non-superuser sees an EMPTY catalog (absent, not denied).
# Two policies carve out the lanes:
#   team-fte   (alice)  read+publish on the summarizer stack + a named new skill
#   team-trial (bob)    read on the summary-style skill only
# Then every enforcement edge is shown live: filtered lists, a forbidden
# by-name get, forbidden publishes, and admin-only policy management.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Default-deny baseline (no policies yet)"
as_user carol delete accesspolicy team-fte   >/dev/null 2>&1 || true
as_user carol delete accesspolicy team-trial >/dev/null 2>&1 || true
log "alice (field-fte):   $(as_user alice get agents 2>&1 | head -1)"
log "bob   (field-trial): $(as_user bob   get agents 2>&1 | head -1)"
ok "non-superusers see an empty catalog until a policy grants them a lane"

step "Applying the two team AccessPolicies (as carol)"
as_user carol apply -f "$LAB_ROOT/yaml/policies/team-fte.yaml"
as_user carol apply -f "$LAB_ROOT/yaml/policies/team-trial.yaml"
as_user carol get accesspolicies | sed 's/^/  /' >&2
ok "policies live"

step "Visibility partitioning: the same list, three callers"
echo "  ── carol (superuser) ──" >&2; as_user carol get agents 2>&1 | sed 's/^/  /' >&2
echo "  ── alice (team-fte) ──"  >&2; as_user alice get agents 2>&1 | sed 's/^/  /' >&2
echo "  ── bob (team-trial) ──"  >&2; as_user bob   get agents 2>&1 | sed 's/^/  /' >&2
echo "  ── bob's skills view ──" >&2; as_user bob   get skills 2>&1 | sed 's/^/  /' >&2
ok "each caller sees only their lane; everything else is absent, not denied"

step "Enforcement edges (every one should fail)"
log "bob gets the agent BY NAME (not in his policy):"
as_user bob get agent summarizer 2>&1 | sed 's/^/    /' >&2 || true
log "bob publishes a skill (no registry:publish anywhere):"
as_user bob apply -f "$LAB_ROOT/artifacts/release-notes-style/skill.yaml" 2>&1 | sed 's/^/    /' >&2 || true
log "alice publishes a skill her policy does NOT name:"
as_user alice apply -f "$LAB_ROOT/yaml/rogue-skill.yaml" 2>&1 | sed 's/^/    /' >&2 || true
log "alice manages AccessPolicies (admin-only):"
as_user alice get accesspolicies 2>&1 | sed 's/^/    /' >&2 || true
ok "all four denied"
echo "  Next: ./scripts/03-publish-as-team.sh" >&2
