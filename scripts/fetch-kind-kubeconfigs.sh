#!/usr/bin/env bash
# fetch-kind-kubeconfigs.sh — laptop-side: pull kind kubeconfigs from a
# remote host, open SSH tunnels to each API server, hold the tunnels in
# the foreground.
#
# Companion to scripts/export-kubeconfig.sh which runs on the remote.
#
# Usage:
#   ./scripts/fetch-kind-kubeconfigs.sh user@host        # default: fetch + merge into ~/.kube/config + tunnel
#   ./scripts/fetch-kind-kubeconfigs.sh user@host --no-tunnel
#   ./scripts/fetch-kind-kubeconfigs.sh user@host --no-merge   # don't touch ~/.kube/config (legacy behaviour)
#   ./scripts/fetch-kind-kubeconfigs.sh user@host --out /custom/dir
#
# Assumes SSH keys are configured (no password prompts) and scp works
# between machines.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

OUT="${OUT:-$HOME/.kube/kind}"
TUNNEL=1
MERGE=1
HOST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-tunnel) TUNNEL=0;  shift ;;
    --no-merge)  MERGE=0;   shift ;;
    --out)       OUT="$2";  shift 2 ;;
    -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          die "unknown flag: $1" ;;
    *)           [[ -z "$HOST" ]] || die "extra positional arg: $1"
                 HOST="$1"; shift ;;
  esac
done

[[ -n "$HOST" ]] || die "missing <user@host>"
ssh_reachable "$HOST" || die "can't ssh to $HOST (key authorized? host reachable?)"

mkdir -p "$OUT"
REMOTE_OUT="/tmp/kind-kc.$$"

# Run the remote-side script via stdin pipe — remote needs no pre-installed
# copy. The remote script writes per-cluster files to $REMOTE_OUT and prints
# `<path>.yaml   (API port <N>)` lines to its stderr (which we capture).
#
# PATH prefix: non-interactive ssh sessions don't source ~/.bashrc / ~/.zshrc,
# so kind / kubectl / etc. may not be on the remote PATH. The snippet from
# remote_path_prefix() probes each candidate dir at exec time on the remote
# so this works for both macOS (with /opt/homebrew) and Linux remotes.
log "fetching kubeconfigs from $HOST"
TMP_STDERR="$(mktemp -t kind-kc.XXXXXX)"
trap 'rm -f "$TMP_STDERR"' EXIT

REMOTE_PATH_PREFIX="$(remote_path_prefix)"

if ! ssh_q "$HOST" "$REMOTE_PATH_PREFIX bash -s -- -o $REMOTE_OUT" \
       < "$SCRIPT_DIR/export-kubeconfig.sh" \
       2> "$TMP_STDERR"; then
  # Surface what the remote actually said before the EXIT trap nukes the file.
  echo "" >&2
  echo "── remote script output (from $HOST) ──" >&2
  cat "$TMP_STDERR" >&2
  echo "" >&2
  die "remote export script failed (output above)"
fi

# Parse cluster + port out of the remote script's output.
PORTS=()
CLUSTERS=()
while IFS= read -r line; do
  if [[ "$line" =~ ([^[:space:]]+\.yaml)[[:space:]]+\(API[[:space:]]port[[:space:]]([0-9]+)\) ]]; then
    fp="${BASH_REMATCH[1]}"
    PORTS+=("${BASH_REMATCH[2]}")
    CLUSTERS+=("$(basename "$fp" .yaml)")
  fi
done < "$TMP_STDERR"
(( ${#PORTS[@]} > 0 )) || { cat "$TMP_STDERR" >&2; die "couldn't parse kubeconfigs from remote output"; }

# Copy the kubeconfigs back. -O forces SCP protocol on OpenSSH ≥9 where scp
# moved to SFTP and remote globs broke.
scp_q -Oq "${HOST}:${REMOTE_OUT}/*.yaml" "$OUT/" 2>/dev/null \
  || scp_q -q "${HOST}:${REMOTE_OUT}/*.yaml" "$OUT/" \
  || die "scp from $HOST failed"

# Clean up remote temp dir.
ssh_q "$HOST" "rm -rf -- $REMOTE_OUT" >/dev/null 2>&1 || true

ok "${#CLUSTERS[@]} kubeconfigs in $OUT/"
for i in "${!CLUSTERS[@]}"; do
  log "${CLUSTERS[$i]}.yaml   (API port ${PORTS[$i]})"
done

# Purge stale per-cluster yamls that aren't in this fetch's fresh set.
# Without this, an earlier 'export KUBECONFIG=$(ls $OUT/*.yaml | tr ...)'
# keeps pulling torn-down clusters into k9s alongside the new ones.
for f in "$OUT"/*.yaml; do
  [[ -f "$f" ]] || continue
  bn="$(basename "$f" .yaml)"
  keep=0
  for c in "${CLUSTERS[@]}"; do [[ "$c" == "$bn" ]] && { keep=1; break; }; done
  if [[ $keep -eq 0 ]]; then
    rm -f "$f"
    log "purged stale $OUT/${bn}.yaml"
  fi
done

# ── Merge into ~/.kube/config + purge stale kind-* contexts ──────────────────
# Without this step, k9s (which reads ~/.kube/config by default) keeps showing
# torn-down kind-east-istio / kind-west-istio etc. entries from previous runs
# and the freshly-fetched contexts don't appear at all. Merge writes the new
# entries into the default kubeconfig and removes any stale kind-* context
# that's NOT in this fetch's fresh set.
if [[ "$MERGE" -eq 1 ]]; then
  command -v kubectl >/dev/null 2>&1 || die "kubectl required for --merge — install it or pass --no-merge"

  DEFAULT_KC="${KUBECONFIG_DEFAULT:-$HOME/.kube/config}"
  mkdir -p "$(dirname "$DEFAULT_KC")"
  touch "$DEFAULT_KC"

  # Build a set of fresh kind context names this fetch produced. The kubeconfigs
  # `kind` generates put `kind-<name>` as both the context and cluster name.
  FRESH=()
  for c in "${CLUSTERS[@]}"; do FRESH+=("kind-$c"); done

  # Also collect LOCAL kind clusters living on this host — they must be
  # preserved across a fetch run. Without this guard the purge wipes out
  # contexts like kind-east-laptop when fetching the remote's kind-west-mini.
  LOCAL_KIND_CTXS=()
  if command -v kind >/dev/null 2>&1; then
    while IFS= read -r local_kind; do
      [[ -n "$local_kind" ]] && LOCAL_KIND_CTXS+=("kind-$local_kind")
    done < <(kind get clusters 2>/dev/null || true)
  fi

  # Purge stale kind-* contexts/clusters/users from the default kubeconfig.
  # Skip anything not prefixed kind- (other contexts are untouched), and skip
  # any kind-* that corresponds to a CLUSTER STILL PRESENT LOCALLY.
  for STALE in $(KUBECONFIG="$DEFAULT_KC" kubectl config get-contexts -o name 2>/dev/null | grep '^kind-' || true); do
    keep=0
    for f in "${FRESH[@]}"; do [[ "$f" == "$STALE" ]] && { keep=1; break; }; done
    if [[ $keep -eq 0 ]]; then
      for l in "${LOCAL_KIND_CTXS[@]:-}"; do
        [[ -n "${l:-}" && "$l" == "$STALE" ]] && { keep=1; break; }
      done
    fi
    if [[ $keep -eq 0 ]]; then
      KUBECONFIG="$DEFAULT_KC" kubectl config delete-context "$STALE" >/dev/null 2>&1 || true
      KUBECONFIG="$DEFAULT_KC" kubectl config delete-cluster "$STALE" >/dev/null 2>&1 || true
      KUBECONFIG="$DEFAULT_KC" kubectl config delete-user    "$STALE" >/dev/null 2>&1 || true
      log "purged stale context $STALE from $DEFAULT_KC"
    fi
  done

  # If a local kind cluster's context isn't currently in the default kubeconfig
  # (e.g. an earlier fetch already nuked it), re-export it via `kind` so future
  # runs preserve it cleanly.
  for l in "${LOCAL_KIND_CTXS[@]:-}"; do
    [[ -z "${l:-}" ]] && continue
    if ! KUBECONFIG="$DEFAULT_KC" kubectl config get-contexts -o name 2>/dev/null | grep -qx "$l"; then
      cname="${l#kind-}"
      KUBECONFIG="$DEFAULT_KC" kind export kubeconfig --name "$cname" >/dev/null 2>&1 || true
      log "re-exported local kind cluster $cname into $DEFAULT_KC"
    fi
  done

  # Merge the freshly-fetched kubeconfigs into the default.
  # `kubectl config view --merge --flatten` resolves the union into one file.
  MERGE_LIST="$DEFAULT_KC"
  for c in "${CLUSTERS[@]}"; do MERGE_LIST="$MERGE_LIST:$OUT/$c.yaml"; done

  TMP_KC="$(mktemp -t kube-cfg.XXXXXX)"
  if ! KUBECONFIG="$MERGE_LIST" kubectl config view --merge --flatten > "$TMP_KC" 2>/dev/null; then
    rm -f "$TMP_KC"
    die "kubectl config view failed during merge"
  fi
  # Atomic replace.
  chmod 600 "$TMP_KC"
  mv -f "$TMP_KC" "$DEFAULT_KC"
  ok "merged ${#CLUSTERS[@]} contexts into $DEFAULT_KC (stale kind-* contexts purged)"
fi

# Print the usage block — what to run in another terminal while the tunnel
# session (below) holds the API ports open.
log ""
log "── how to use these on this laptop ──"
log ""
if [[ "$MERGE" -eq 1 ]]; then
  log "  # Just run k9s — the fresh contexts are now in ~/.kube/config:"
  log "  k9s"
  log ""
  log "  Switch contexts inside k9s with  :ctx"
  log ""
  log "  # Or scope to one cluster file:"
  log "  KUBECONFIG=$OUT/${CLUSTERS[0]}.yaml k9s"
else
  log "  # One specific cluster:"
  log "  KUBECONFIG=$OUT/${CLUSTERS[0]}.yaml k9s"
  if (( ${#CLUSTERS[@]} > 1 )); then
    log ""
    log "  # Or all clusters in one k9s session (colon-separated KUBECONFIG):"
    log "  export KUBECONFIG=\$(ls $OUT/*.yaml | tr '\\n' ':')"
    log "  k9s"
    log ""
    log "  Switch contexts inside k9s with  :ctx"
  fi
fi
log ""

if [[ "$TUNNEL" -eq 0 ]]; then
  log "tunnel command (run separately to enable the API ports):"
  printf "  ssh" >&2
  for P in "${PORTS[@]}"; do printf " -L %s:localhost:%s" "$P" "$P" >&2; done
  printf " %s\n" "$HOST" >&2
  exit 0
fi

# Build the tunnel command + exec.
TUNNEL_ARGS=()
for P in "${PORTS[@]}"; do TUNNEL_ARGS+=(-L "${P}:localhost:${P}"); done

log ""
ok "opening SSH tunnel (Ctrl-C to close)"
exec ssh "${SSH_OPTS[@]}" "${TUNNEL_ARGS[@]}" "$HOST"
