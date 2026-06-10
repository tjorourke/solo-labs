#!/usr/bin/env bash
# 03-publish-as-team.sh — alice publishes inside her lane.
#
# team-fte grants registry:publish on the skill `release-notes-style` BY NAME,
# so alice can publish exactly that artifact and nothing else. After the
# publish the partition still holds: alice sees the new skill, bob does not
# (it is not in his policy), carol sees everything.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "alice publishes release-notes-style (named in team-fte)"
as_user carol delete skill release-notes-style >/dev/null 2>&1 || true   # idempotent rerun
as_user alice apply -f "$LAB_ROOT/artifacts/release-notes-style/skill.yaml"
ok "published as alice, no admin involved"

step "The partition after the publish"
echo "  ── alice's skills ──" >&2; as_user alice get skills 2>&1 | sed 's/^/  /' >&2
echo "  ── bob's skills ──"   >&2; as_user bob   get skills 2>&1 | sed 's/^/  /' >&2
echo "  ── carol's skills ──" >&2; as_user carol get skills 2>&1 | sed 's/^/  /' >&2
ok "alice + carol see release-notes-style; for bob it does not exist"

step "Done"
cat >&2 <<'EOF'

  The registry is now identity-partitioned:
    carol (field-admin)  superuser: full catalog + policy management
    alice (field-fte)    summarizer stack, may publish one named skill
    bob   (field-trial)  one skill, read-only

  Inspect as anyone:   ./scripts/tokens.sh alice | xargs -I{} arctl get skills --registry-token {}
  Revert to part 1:    ./scripts/quick.sh down
EOF
