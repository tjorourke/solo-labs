#!/usr/bin/env bash
# 00-prereqs.sh — install and validate everything the demo needs before the
# first cluster comes up. Idempotent: re-run it any time. On macOS it installs
# missing CLIs with Homebrew; on Linux it points you at the right package.
# arctl is always installed/pinned from the official Solo bucket to $ARCTL_VERSION.
#
# Usage:
#   ./scripts/00-prereqs.sh           # validate, install what's missing
#   ./scripts/00-prereqs.sh --check   # validate only, never install (CI-style)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

OS="$(uname -s)"
have() { command -v "$1" >/dev/null 2>&1; }

# brew_install <brew-formula-or-cask> — install on macOS, otherwise just warn.
brew_install() {
  local what="$1" cask="${2:-}"
  if (( CHECK_ONLY )); then warn "missing: $what (run without --check to install)"; return 1; fi
  if [[ "$OS" == "Darwin" ]] && have brew; then
    log "brew install ${cask:+--cask }$what"
    if [[ -n "$cask" ]]; then brew install --cask "$what" >/dev/null; else brew install "$what" >/dev/null; fi
  else
    die "$what not found — install it for your platform, then re-run"
  fi
}

missing=0

# ── core CLIs ────────────────────────────────────────────────────────────────
# Map cli -> Homebrew formula via a case (not an assoc array — macOS ships bash
# 3.2, which has no `declare -A`).
step "Core tooling"
formula_for() {
  case "$1" in
    *)        echo "$1" ;;
  esac
}
for cli in docker kind kubectl helm jq gh uv curl openssl; do
  if have "$cli"; then ok "$cli: $(command -v "$cli")"; else
    warn "$cli not found"; missing=1
    case "$cli" in
      docker) brew_install docker docker || true ;;   # cask
      *)      brew_install "$(formula_for "$cli")" || true ;;
    esac
  fi
done

# ── cloud CLIs ───────────────────────────────────────────────────────────────
step "Cloud CLIs (AWS for AgentCore, gcloud for Solo's public Helm charts)"
if have aws; then ok "aws: $(aws --version 2>&1 | head -1)"; else warn "aws not found"; missing=1; brew_install awscli || true; fi
if have gcloud; then ok "gcloud: present"; else warn "gcloud not found"; missing=1; brew_install google-cloud-sdk google-cloud-sdk || true; fi

# ── docker daemon ────────────────────────────────────────────────────────────
step "Docker daemon"
if docker info >/dev/null 2>&1; then ok "docker daemon reachable"; else warn "docker daemon not reachable — start Docker Desktop"; missing=1; fi

# ── arctl (pinned) ───────────────────────────────────────────────────────────
step "arctl ${ARCTL_VERSION} (enterprise; in-cluster registry model — no local daemon)"
need_install=1
if have arctl; then
  cur="$(arctl version 2>/dev/null | awk '/arctl version/{print $3}')"
  if [[ "$cur" == "$ARCTL_VERSION" ]]; then ok "arctl ${cur} already installed"; need_install=0
  else log "arctl ${cur:-none} present, want ${ARCTL_VERSION}"; fi
fi
if (( need_install )); then
  if (( CHECK_ONLY )); then warn "arctl ${ARCTL_VERSION} not installed (run without --check)"; missing=1; else
    log "installing arctl ${ARCTL_VERSION} from ${ARCTL_INSTALL_URL%/*}"
    curl -sSL "$ARCTL_INSTALL_URL" | ARCTL_VERSION="$ARCTL_VERSION" sh >/dev/null \
      || die "arctl install failed"
    export PATH="$HOME/.arctl/bin:$PATH"
    have arctl || die "arctl not on PATH — add: export PATH=\$HOME/.arctl/bin:\$PATH"
    ok "arctl installed: $(arctl version 2>/dev/null | awk '/arctl version/{print $3}')"
  fi
fi
# v2026.6.x drops the local `daemon` (the registry is now the in-cluster server);
# `arctl user login` + init/build/run are what we use. Nothing daemon-specific to check.
echo "  Add arctl to PATH for this shell:  export PATH=\$HOME/.arctl/bin:\$PATH" >&2

# ── secrets / auth reminders (validated, not installed) ──────────────────────
step "Credentials (not installed — just checked)"
load_secrets || true
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && ok "ANTHROPIC_API_KEY set" || { warn "ANTHROPIC_API_KEY not set (agent model)"; missing=1; }
[[ -n "${SOLO_LICENSE_KEY:-}${KAGENT_ENT_LICENSE_KEY:-}" ]] && ok "Solo license set" || { warn "SOLO_LICENSE_KEY not set (Solo Enterprise for kagent)"; missing=1; }
if gcloud auth print-access-token >/dev/null 2>&1; then ok "gcloud authenticated (Helm OCI pull)"; else warn "gcloud not authenticated — run: gcloud auth login"; fi
if have aws && aws sts get-caller-identity >/dev/null 2>&1; then ok "AWS session live"; else log "no live AWS session yet — needed only for the AgentCore path (aws sso login)"; fi

step "Prereqs summary"
if (( missing )); then
  warn "some prerequisites are missing or unset — see the lines above"
  exit 1
fi
ok "all prerequisites satisfied"
echo "  Next: ./scripts/quick.sh up" >&2
