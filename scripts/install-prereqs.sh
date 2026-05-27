#!/usr/bin/env bash
# install-prereqs.sh — audit (and optionally install) every tool the labs +
# scripts in this repo expect.
#
# Default: read-only check — prints what's installed, what's missing.
# Add --install to actually install the missing ones via Homebrew (macOS) or
# print install hints (Linux).
#
# Usage:
#   ./scripts/install-prereqs.sh              # check only
#   ./scripts/install-prereqs.sh --install    # install everything missing
#   ./scripts/install-prereqs.sh --required   # only check/install required tools
#
# What it covers:
#
#   Required for kind labs (quick.sh, quick-single.sh)
#     docker     — kind nodes are Docker containers (Docker Desktop on macOS)
#     kind       — cluster orchestrator
#     kubectl    — operate the cluster
#     helm       — install Solo Istio, agentgateway, gloo-platform
#     openssl    — generate the shared root CA + per-cluster intermediates
#     istioctl   — Solo build (multicluster commands); fetched from the Solo
#                  storage bucket — see install_solo_istioctl() below.
#     python3    — peer-with.sh uses it to rewrite remote-secret YAML
#
#   Useful for driving / observing
#     k9s        — TUI for kubectl. Best way to navigate kind clusters.
#     meshctl    — Solo CLI; needed if you run the Gloo UI step (STEP 12).
#
# Skipped intentionally
#     gcloud     — only needed if pulling Solo Istio images from a registry
#                  that requires `gcloud auth configure-docker`. Public Solo
#                  registries don't, so we don't make this script handle it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

INSTALL=0
REQUIRED_ONLY=0

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)  INSTALL=1;       shift ;;
    --required) REQUIRED_ONLY=1; shift ;;
    -h|--help)  usage 0 ;;
    *)          die "unknown arg: $1" ;;
  esac
done

OS="$(uname -s)"

# ── tool table ───────────────────────────────────────────────────────────────
# fields:  name | check-cmd | required (1|0) | macos-brew-formula | linux-hint
TOOLS=(
  "docker|docker --version|1|docker|install Docker Engine from https://docs.docker.com/engine/install/"
  "kind|kind --version|1|kind|go install sigs.k8s.io/kind@latest, or grab a release from https://kind.sigs.k8s.io/"
  "kubectl|kubectl version --client=true --output=yaml|1|kubectl|see https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/"
  "helm|helm version --short|1|helm|see https://helm.sh/docs/intro/install/"
  "openssl|openssl version|1|openssl|preinstalled on most distros; apt install openssl"
  "python3|python3 --version|1|python|preinstalled on most distros; apt install python3"
  "k9s|k9s version --short|0|derailed/k9s/k9s|see https://k9scli.io/topics/install/"
  "meshctl|meshctl version --plain client 2>/dev/null|1|MESHCTL_SPECIAL|see https://run.solo.io/meshctl/install"
)

# ── Homebrew bootstrap (macOS) ────────────────────────────────────────────────

ensure_brew() {
  if command -v brew >/dev/null 2>&1; then return 0; fi
  if [[ "$INSTALL" -ne 1 ]]; then
    warn "Homebrew not installed (needed to auto-install on macOS)"
    return 1
  fi
  log "Installing Homebrew (one-time, interactive — needs sudo password)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Append /opt/homebrew/bin to PATH for this session.
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
}

# ── check / install one tool ─────────────────────────────────────────────────

check_one() {
  local name="$1" check="$2" required="$3" brew_formula="$4" linux_hint="$5"
  local installed=0 version=""

  if version="$(eval "$check" 2>&1 | head -1)"; then
    if command -v "$name" >/dev/null 2>&1; then installed=1; fi
  fi

  local tag="optional"
  [[ "$required" == "1" ]] && tag="required"

  if [[ "$installed" == "1" ]]; then
    ok "$name ($tag) — $version"
    return 0
  fi

  # Not installed.
  if [[ "$INSTALL" -ne 1 ]]; then
    if [[ "$required" == "1" ]]; then
      warn "$name (required) — NOT installed"
    else
      log "$name (optional) — not installed"
    fi
    return 1
  fi

  # --install path
  warn "$name not installed — installing…"

  # meshctl ships from run.solo.io — not Homebrew. Handle via the upstream
  # installer script and put the binary on PATH for the current session.
  if [[ "$brew_formula" == "MESHCTL_SPECIAL" ]]; then
    install_meshctl
    command -v meshctl >/dev/null 2>&1 \
      && ok "meshctl installed" \
      || warn "meshctl install finished, but binary still not on PATH — add ~/.gloo-mesh/bin to PATH"
    return
  fi

  case "$OS" in
    Darwin)
      ensure_brew || { warn "skipping $name (brew unavailable)"; return 1; }
      brew install "$brew_formula"
      ;;
    Linux)
      # docker is too distro-specific (engine vs desktop vs rootless) — never
      # auto-install; always hint. kind / kubectl / helm / k9s / istioctl
      # don't live in default distro repos for most setups either, so we hint
      # for those too. openssl + python3 are safe to apt-install if the user
      # passes --install. The hint always tells them the exact command for
      # their detected package manager.
      local mgr; mgr="$(detect_pkg_mgr)"
      if [[ "$name" =~ ^(openssl|python3)$ ]]; then
        case "$mgr" in
          apt)    log "$name on Linux ($mgr): sudo apt-get install -y $name"
                  sudo apt-get install -y "$name" || { warn "apt-get install $name failed"; return 1; } ;;
          dnf)    log "$name on Linux ($mgr): sudo dnf install -y $name"
                  sudo dnf install -y "$name" || { warn "dnf install $name failed"; return 1; } ;;
          pacman) log "$name on Linux ($mgr): sudo pacman -S --noconfirm $name"
                  sudo pacman -S --noconfirm "$name" || { warn "pacman -S $name failed"; return 1; } ;;
          *)      warn "$name on Linux ($mgr): install via your package manager — $linux_hint"
                  return 1 ;;
        esac
      else
        # Tools where auto-install is unsafe or not available in default repos —
        # surface the exact pkg-mgr command (in case it IS available) plus the
        # canonical install doc from the TOOLS table.
        case "$mgr" in
          apt)    warn "$name on Linux ($mgr): try 'sudo apt-get install $name' or follow: $linux_hint" ;;
          dnf)    warn "$name on Linux ($mgr): try 'sudo dnf install $name' or follow: $linux_hint" ;;
          pacman) warn "$name on Linux ($mgr): try 'sudo pacman -S $name' or follow: $linux_hint" ;;
          *)      warn "$name on Linux ($mgr): $linux_hint" ;;
        esac
        return 1
      fi
      ;;
    *)
      warn "$name: unsupported OS $OS"
      return 1
      ;;
  esac

  command -v "$name" >/dev/null 2>&1 && ok "$name installed" || warn "$name install attempt finished, but binary still not on PATH"
}

# ── meshctl installer (curl-based, not Homebrew) ──────────────────────────────
# Installs into ~/.gloo-mesh/bin/meshctl and exports the dir to PATH for the
# rest of this script invocation. The user still needs to add it to their
# shell rc themselves for future shells; we print the hint at the end.
#
# Pin GLOO_MESH_VERSION so the labs always get the version known to work with
# the Solo Istio + agentgateway charts the quick.sh scripts install. Override
# with MESHCTL_VERSION=v2.12.4 ./scripts/install-prereqs.sh --install if you
# need to chase a newer one.
MESHCTL_VERSION="${MESHCTL_VERSION:-v2.12.3}"

install_meshctl() {
  log "fetching meshctl ($MESHCTL_VERSION) from run.solo.io"
  local installer="/tmp/meshctl-install.$$.sh"
  if ! curl -fsSL https://run.solo.io/meshctl/install -o "$installer"; then
    warn "couldn't download meshctl installer"
    return 1
  fi
  if ! GLOO_MESH_VERSION="$MESHCTL_VERSION" sh "$installer"; then
    warn "meshctl install script failed (see output above)"
    rm -f "$installer"
    return 1
  fi
  rm -f "$installer"
  export PATH="$HOME/.gloo-mesh/bin:$PATH"
  log "meshctl installed to ~/.gloo-mesh/bin — add this to your shell rc:"
  log "    export PATH=\"\$HOME/.gloo-mesh/bin:\$PATH\""
}

# ── Solo istioctl installer (Solo storage bucket, not Homebrew) ───────────────
# Upstream istioctl (homebrew / istio.io) is missing the `multicluster check`,
# `multicluster expose`, and `bootstrap` subcommands the multicluster labs
# need. The Solo build lives in a Solo-hosted storage bucket keyed by REPO_KEY
# (public default below).
#
# Override via env vars when invoking install-prereqs.sh:
#   REPO_KEY        Solo storage bucket key (default e6283d67ad60, public).
#   ISTIO_VERSION   Istio version (default 1.29.2). A -solo suffix is appended.
#   ISTIO_BIN_DIR   Install location (default ~/.istioctl/bin).
REPO_KEY="${REPO_KEY:-e6283d67ad60}"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.2}"
ISTIO_BIN_DIR="${ISTIO_BIN_DIR:-$HOME/.istioctl/bin}"

install_solo_istioctl() {
  local os arch tmp archive=""
  os=$(uname | tr '[:upper:]' '[:lower:]' | sed -E 's/darwin/osx/')
  arch=$(uname -m | sed -E 's/aarch64/arm64/; s/x86_64/amd64/; s/armv7l/armv7/')

  mkdir -p "$ISTIO_BIN_DIR"
  tmp=$(mktemp -d)

  # Bucket layout varies — try the most common artifact name patterns in
  # order until one returns a real archive. curl -f makes us exit non-zero
  # on 4xx/5xx so we never pipe an HTTP error page into tar (which produces
  # the misleading "Unrecognized archive format" error).
  local base="https://storage.googleapis.com/istio-binaries-${REPO_KEY}/${ISTIO_VERSION}-solo"
  local candidates=(
    "${base}/istioctl-${ISTIO_VERSION}-solo-${os}-${arch}.tar.gz"
    "${base}/istioctl-${ISTIO_VERSION}-${os}-${arch}.tar.gz"
    "${base}/istio-${ISTIO_VERSION}-solo-${os}-${arch}.tar.gz"
  )

  local url
  for url in "${candidates[@]}"; do
    log "trying $url"
    if curl -fsSL --output "$tmp/istioctl.tar.gz" "$url"; then
      if file "$tmp/istioctl.tar.gz" | grep -q "gzip compressed"; then
        archive="$tmp/istioctl.tar.gz"
        log "  ✓ valid gzip archive"
        break
      else
        log "  ✗ downloaded file isn't a gzip archive — skipping"
      fi
    fi
  done

  if [[ -z "$archive" ]]; then
    warn "could not download a Solo istioctl archive"
    warn "  REPO_KEY=$REPO_KEY ISTIO_VERSION=$ISTIO_VERSION may be wrong or rotated"
    warn "  tried:"
    local u; for u in "${candidates[@]}"; do warn "    $u"; done
    rm -rf "$tmp"
    return 1
  fi

  # The archive may contain just `istioctl` at the top level, or an
  # istio-${VERSION}-solo/ directory with bin/istioctl inside. Handle both.
  tar xzf "$archive" -C "$tmp"
  if [[ -f "$tmp/istioctl" ]]; then
    mv -f "$tmp/istioctl" "$ISTIO_BIN_DIR/istioctl"
  elif [[ -f "$tmp/istio-${ISTIO_VERSION}-solo/bin/istioctl" ]]; then
    mv -f "$tmp/istio-${ISTIO_VERSION}-solo/bin/istioctl" "$ISTIO_BIN_DIR/istioctl"
  else
    warn "extracted archive doesn't contain an istioctl binary at a known path"
    ls -R "$tmp" >&2
    rm -rf "$tmp"
    return 1
  fi

  chmod +x "$ISTIO_BIN_DIR/istioctl"
  rm -rf "$tmp"

  # Make istioctl available for the rest of this script run.
  export PATH="$ISTIO_BIN_DIR:$PATH"

  log "installed $ISTIO_BIN_DIR/istioctl — add this to your shell rc so it stays on PATH:"
  log "    export PATH=\"\$HOME/.istioctl/bin:\$PATH\""
}

# ── special case: istioctl (Solo build) ───────────────────────────────────────
# Upstream istioctl exists in brew but the labs need the SOLO build. Detect
# either, and steer the user to --install if upstream is in place but the
# Solo multicluster commands are missing.

check_istioctl() {
  if ! command -v istioctl >/dev/null 2>&1; then
    if [[ "$INSTALL" -eq 1 ]]; then
      log "istioctl not installed — fetching Solo build"
      install_solo_istioctl || warn "Solo istioctl install failed"
      command -v istioctl >/dev/null 2>&1 \
        && ok "istioctl installed (Solo build)" \
        || warn "istioctl still not on PATH"
    else
      warn "istioctl (required) — NOT installed.  Run ./scripts/install-prereqs.sh --install"
    fi
    return
  fi

  # --remote=false skips the in-cluster istiod contact. Without it, istioctl
  # tries to reach the API server's istiod pod, which hangs (or times out
  # after ~30s) on a laptop with no live kube-context.
  local v; v="$(istioctl version --short --remote=false 2>&1 | head -1 || true)"
  if [[ "$v" == *-solo* ]]; then
    ok "istioctl (required) — Solo build $v"
  else
    warn "istioctl present but appears to be UPSTREAM ($v) — Solo multicluster commands won't work"
    warn "  fix: ./scripts/install-prereqs.sh --install   (installs Solo build into ~/.istioctl/bin)"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────

echo "── prereq audit (OS: $OS) ──"
echo ""

missing_required=0
for line in "${TOOLS[@]}"; do
  IFS='|' read -r name check required brew_formula linux_hint <<< "$line"
  if [[ "$REQUIRED_ONLY" -eq 1 && "$required" != "1" ]]; then
    continue
  fi
  if ! check_one "$name" "$check" "$required" "$brew_formula" "$linux_hint"; then
    [[ "$required" == "1" ]] && missing_required=$((missing_required + 1))
  fi
done

echo ""
check_istioctl

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
if [[ "$INSTALL" -eq 1 ]]; then
  ok "install pass complete"
  log "re-run without --install to confirm everything's on PATH"
elif [[ "$missing_required" -gt 0 ]]; then
  warn "$missing_required required tool(s) missing"
  log "re-run with --install to install via Homebrew (macOS) or follow the hints"
  exit 1
else
  ok "all required tools present"
  log "run with --install to also pick up optional ones (k9s, meshctl)"
fi
