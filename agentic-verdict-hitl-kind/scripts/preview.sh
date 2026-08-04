#!/usr/bin/env bash
# preview.sh — which agents would the register gate, and on which tools?
#
# The verdict label on an Agent tells you the decision, but not what it resolved to:
# an agent can be labelled red and still be gated on nothing, because the register
# says nothing about the MCP servers that agent happens to use. And a label only ever
# tells you about the register as it is now, never about a change you are considering.
#
# This answers both, without touching the cluster. It runs the REAL policy against the
# REAL agents with the Kyverno CLI, so what it prints is what admission would do:
#
#   ./scripts/preview.sh                          # what the current register does
#   ./scripts/preview.sh --red '*'                # ...if red were "*"
#   ./scripts/preview.sh --red '' --default red   # ...if the posture were deny-by-default
#   ./scripts/preview.sh --gated-file ./g.yaml    # ...with a different gated list
#
# Nothing here writes. Use it before editing the register, then again afterwards.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require kyverno
POLICY="$LAB_ROOT/yaml/kyverno/20-verdict-hitl.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── the register: live values, with optional overrides ────────────────────────
REG_JSON="$(kc -n kyverno get configmap agent-risk-register -o json 2>/dev/null)" \
  || die "no agent-risk-register in the kyverno namespace — run ./scripts/07-verdict.sh"
[[ -n "$REG_JSON" ]] || die "no agent-risk-register in the kyverno namespace"

read_key() { printf '%s' "$REG_JSON" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('data', {}).get('$1', '') or '')"; }

RED="$(read_key red)"
DEFAULT="$(read_key default)"; DEFAULT="${DEFAULT:-green}"
GATED="$(read_key gated)"; GATED="${GATED:-[]}"
OVERRIDDEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --red)        RED="$2";     OVERRIDDEN="yes"; shift 2 ;;
    --default)    DEFAULT="$2"; OVERRIDDEN="yes"; shift 2 ;;
    --gated-file) [[ -f "$2" ]] || die "no such file: $2"
                  GATED="$(cat "$2")"; OVERRIDDEN="yes"; shift 2 ;;
    -h|--help)    sed -n '2,20p' "$0" >&2; exit 0 ;;
    *)            die "unknown flag: $1 (see --help)" ;;
  esac
done

step "The register being previewed"
if [[ -n "$OVERRIDDEN" ]]; then
  warn "these are OVERRIDES — the cluster still has its current register"
fi
log "red     = ${RED:-(none)}"
log "default = ${DEFAULT}"
log "gated:"
printf '%s\n' "$GATED" | sed 's/^/      /' >&2

# ── the agents, exactly as the cluster holds them ─────────────────────────────
# `kubectl get -o yaml` wraps everything in a kind: List, and the Kyverno CLI does
# NOT unwrap it: it matches nothing, reports "pass: 0, fail: 0", exits 0, and every
# agent previews as unchanged. Split the items into separate documents.
kc -n "$KAGENT_NS" get agents.kagent.dev -o yaml > "$WORK/raw.yaml" 2>/dev/null \
  || die "cannot read agents in namespace $KAGENT_NS"
COUNT="$(python3 - "$WORK/raw.yaml" "$WORK/live.yaml" <<'SPLIT'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
items = d.get('items', [d] if d.get('kind') == 'Agent' else [])
with open(sys.argv[2], 'w') as f:
    for i, it in enumerate(items):
        # status is server-owned and irrelevant to admission; dropping it keeps the
        # diff readable and avoids the CLI choking on managed fields.
        it.pop('status', None)
        it.get('metadata', {}).pop('managedFields', None)
        if i:
            f.write('---\n')
        yaml.safe_dump(it, f, default_flow_style=False, sort_keys=False)
print(len(items))
SPLIT
)"
[[ "$COUNT" == "0" ]] && { log "no agents deployed yet"; exit 0; }
log "previewing against ${COUNT} live agent(s)"

# Rule names must match the policy or the CLI leaves the register unresolved and
# every agent silently previews as ungated. Same trap as test-policy.sh.
RULES=(approval-declarative approval-byo ungate-declarative ungate-byo
       ungate-declarative-unlisted ungate-byo-unlisted label-red label-green)
for r in "${RULES[@]}"; do
  grep -q "name: $r" "$POLICY" || die "preview is stale: no rule '$r' in the policy"
done
{
  echo "policies:"
  echo "  - name: verdict-hitl-enrolment"
  echo "    rules:"
  for r in "${RULES[@]}"; do
    echo "      - name: $r"
    echo "        values:"
    echo "          register.data.red: \"$RED\""
    echo "          register.data.default: \"$DEFAULT\""
    echo "          register.data.gated: |"
    printf '%s\n' "$GATED" | sed 's/^/            /'
  done
} > "$WORK/values.yaml"

kyverno apply "$POLICY" --resource "$WORK/live.yaml" \
  --values-file "$WORK/values.yaml" -o "$WORK/out" >/dev/null 2>&1 || true

# The CLI writes one mutated file per resource when -o is a directory; fall back to
# stdout if this build does not.
if [[ -d "$WORK/out" ]]; then
  cat "$WORK/out"/* > "$WORK/after.yaml" 2>/dev/null
else
  kyverno apply "$POLICY" --resource "$WORK/live.yaml" \
    --values-file "$WORK/values.yaml" 2>/dev/null > "$WORK/after.yaml"
fi

# ── before and after, per agent ───────────────────────────────────────────────
step "What admission would do to each agent"
python3 - "$WORK/live.yaml" "$WORK/after.yaml" <<'PY' >&2
import sys, yaml

def gating(d):
    """The tools this Agent would pause on, however its type expresses that."""
    spec = d.get('spec', {})
    if spec.get('type') == 'Declarative':
        out = []
        for st in (spec.get('declarative', {}).get('tools') or []):
            out += (st.get('mcpServer', {}).get('requireApproval') or [])
        return out
    env = (spec.get('byo', {}).get('deployment', {}).get('env') or [])
    v = [e.get('value', '') for e in env if e.get('name') == 'KAGENT_REQUIRE_APPROVAL']
    return [t for t in (v[0].split(',') if v else []) if t]

def load(path):
    out = {}
    txt = open(path).read()
    for blk in txt.split('\n---'):
        for d in yaml.safe_load_all(blk):
            if not isinstance(d, dict):
                continue
            for item in (d.get('items') or [d]):
                if isinstance(item, dict) and item.get('kind') == 'Agent':
                    out[item['metadata']['name']] = item
    return out

before, after = load(sys.argv[1]), load(sys.argv[2])

hdr = '  %-14s %-12s %-8s %-34s %s' % ('AGENT', 'TYPE', 'VERDICT', 'WOULD PAUSE ON', 'CHANGE')
print(hdr)
print('  ' + '-' * (len(hdr) - 2))
for name in sorted(before):
    b, a = before[name], after.get(name, before[name])
    gb, ga = gating(b), gating(a)
    verdict = (a.get('metadata', {}).get('labels') or {}).get(
        'risk.platform.solo.io/verdict', '-')
    if gb == ga:
        change = 'no change'
    elif not gb:
        change = 'NEWLY GATED'
    elif not ga:
        change = 'GATING REMOVED'
    else:
        change = 'changed from %s' % (','.join(gb) or '-')
    print('  %-14s %-12s %-8s %-34s %s' % (
        name, a.get('spec', {}).get('type', '?'), verdict,
        ','.join(ga) if ga else '(nothing)', change))
PY

step "Nothing was changed"
log "the cluster is untouched; this was the policy run against a copy"
