#!/usr/bin/env bash
# bootstrap-linux.sh — install all prereqs to run the Solo agentgateway +
# Istio Ambient kind labs on a fresh Ubuntu/Debian Linux host (AWS EC2,
# bare metal, VM — anywhere with apt).
#
# Standalone: scp this single file to the host and run it. The Solo istioctl
# install runs only if the repo is already present at $REPO_DIR (default:
# ~/code/solo/solo-labs); otherwise it's skipped with a clear hint.
#
# Idempotent: every tool's install is guarded by a `command -v` check, so
# re-running is safe — it'll only do what's missing.
#
# Usage:
#   scp -i ~/.ssh/key.pem scripts/bootstrap-linux.sh ubuntu@host:~
#   ssh -i ~/.ssh/key.pem ubuntu@host
#     bash bootstrap-linux.sh
#
# Override knobs (env):
#   KIND_VERSION       default v0.31.0
#   MESHCTL_VERSION    default v2.12.3
#   REPO_DIR           default $HOME/code/solo/solo-labs

set -Eeuo pipefail

KIND_VERSION="${KIND_VERSION:-v0.31.0}"
MESHCTL_VERSION="${MESHCTL_VERSION:-v2.12.3}"
REPO_DIR="${REPO_DIR:-$HOME/code/solo/solo-labs}"

# ── output helpers ──────────────────────────────────────────────────────────
step() { printf '\n══> %s\n' "$*"; }
log()  { printf '   • %s\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[31mERROR\033[0m: %s\n' "$*" >&2; exit 1; }

# ── distro detection ────────────────────────────────────────────────────────
[[ -r /etc/os-release ]] || die "/etc/os-release missing — unknown distro"
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "this bootstrap supports ubuntu/debian only (detected ID=${ID:-unknown}). Mac users: ./scripts/install-prereqs.sh --install" ;;
esac

USER_NAME="${USER:-$(whoami)}"

# ── 1. System basics ────────────────────────────────────────────────────────
step "System basics (curl, jq, openssl, gnupg, wget, python3 + pip)"
sudo apt-get update -qq
sudo apt-get install -y -qq curl jq openssl ca-certificates gnupg wget python3 python3-pip file
ok "basics installed"

# pyyaml — rugpull-demo's observability scripts (e.g.
# scripts/multi/11-observability-multi.sh) need it for YAML mangling.
# Cheap to install once here vs. each script lazily pip-installing on first
# run (which fails on hosts where pip itself is missing).
if ! python3 -c 'import yaml' 2>/dev/null; then
  log "installing pyyaml (rugpull-demo observability scripts need it)"
  pip3 install --quiet --break-system-packages pyyaml 2>/dev/null \
    || pip3 install --quiet pyyaml 2>/dev/null \
    || sudo apt-get install -y -qq python3-yaml 2>/dev/null \
    || warn "pyyaml install failed — rugpull-demo observability scripts may error"
fi
python3 -c 'import yaml' 2>/dev/null && ok "pyyaml available" || true

# ── 2. Docker ───────────────────────────────────────────────────────────────
step "Docker engine"
if command -v docker >/dev/null 2>&1; then
  ok "docker already present: $(docker --version)"
else
  curl -fsSL https://get.docker.com | sudo sh
  ok "docker installed: $(docker --version)"
fi
if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx docker; then
  ok "$USER_NAME already in docker group"
else
  sudo usermod -aG docker "$USER_NAME"
  warn "added $USER_NAME to docker group — log out + back in (or 'newgrp docker') before running docker"
fi

# ── 2b. Kernel limits — kind multi-cluster on Linux ─────────────────────────
# Default Ubuntu inotify limits exhaust around 2 kind clusters: the second
# cluster's worker kubelet starts but can't TLS-bootstrap because it can't
# allocate inotify watches/instances. Bumping these BEFORE any kind create
# is the cheapest, most-reliable fix.
# Refs: https://kind.sigs.k8s.io/docs/user/known-issues/#pod-errors-due-to-too-many-open-files
step "Kernel limits for kind multi-cluster"
sudo tee /etc/sysctl.d/99-kind-multi.conf >/dev/null <<'SYSCTL_EOF'
fs.inotify.max_user_watches   = 524288
fs.inotify.max_user_instances = 512
fs.file-max                   = 2097152
SYSCTL_EOF
sudo sysctl --system >/dev/null 2>&1 || true
ok "inotify + file-max limits raised (persists across reboots)"

# ── 3. kind ─────────────────────────────────────────────────────────────────
step "kind ($KIND_VERSION)"
CURRENT_KIND="$(kind --version 2>/dev/null | awk '{print $3}' || true)"
if [[ "$CURRENT_KIND" == "${KIND_VERSION#v}" ]]; then
  ok "kind already at ${KIND_VERSION#v}"
else
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
  sudo install -m 0755 /tmp/kind /usr/local/bin/kind && rm /tmp/kind
  ok "kind installed: $(kind --version)"
fi

# ── 4. kubectl (matches the cluster's k8s stable release) ───────────────────
step "kubectl"
if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl already present"
else
  KCT_VER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KCT_VER}/bin/linux/amd64/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl && rm /tmp/kubectl
  ok "kubectl ${KCT_VER} installed"
fi

# ── 5. helm ─────────────────────────────────────────────────────────────────
step "helm"
if command -v helm >/dev/null 2>&1; then
  ok "helm already present: $(helm version --short)"
else
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ok "helm installed"
fi

# ── 6. gcloud SDK (needed for nightly GAR auth) ─────────────────────────────
step "gcloud SDK"
if command -v gcloud >/dev/null 2>&1; then
  ok "gcloud already present"
else
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg
  echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq google-cloud-cli
  ok "gcloud installed"
fi

# ── 7. gh CLI ───────────────────────────────────────────────────────────────
step "gh CLI"
if command -v gh >/dev/null 2>&1; then
  ok "gh already present: $(gh --version | head -1)"
else
  sudo install -m 0755 -d /etc/apt/keyrings
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq gh
  ok "gh installed"
fi

# ── 8. meshctl (Solo CLI) ───────────────────────────────────────────────────
step "meshctl ($MESHCTL_VERSION)"
if [[ -x "$HOME/.gloo-mesh/bin/meshctl" ]] || command -v meshctl >/dev/null 2>&1; then
  ok "meshctl already installed (~/.gloo-mesh/bin)"
else
  curl -fsSL https://run.solo.io/meshctl/install -o /tmp/meshctl-install.sh
  GLOO_MESH_VERSION="$MESHCTL_VERSION" sh /tmp/meshctl-install.sh
  rm -f /tmp/meshctl-install.sh
  ok "meshctl installed (~/.gloo-mesh/bin)"
fi

# ── 9. PATH wiring (idempotent — only appends if line not already present) ──
step "PATH wiring in ~/.bashrc"
BRC="$HOME/.bashrc"
touch "$BRC"
add_path_line() {
  local line="$1"
  grep -Fqx "$line" "$BRC" || { echo "$line" >> "$BRC"; log "added: $line"; }
}
add_path_line 'export PATH="$HOME/.istioctl/bin:$PATH"'
add_path_line 'export PATH="$HOME/.gloo-mesh/bin:$PATH"'
ok "PATH lines present in ~/.bashrc (source it or open a new shell)"

# ── 10. Solo istioctl ───────────────────────────────────────────────────────
step "Solo istioctl"
if [[ -x "$HOME/.istioctl/bin/istioctl" ]]; then
  ok "Solo istioctl already installed (~/.istioctl/bin)"
elif [[ -x "$REPO_DIR/scripts/install-prereqs.sh" ]]; then
  log "delegating to $REPO_DIR/scripts/install-prereqs.sh --install"
  ( cd "$REPO_DIR" && bash scripts/install-prereqs.sh --install ) || warn "install-prereqs.sh reported errors — review above"
  if [[ -x "$HOME/.istioctl/bin/istioctl" ]]; then
    ok "Solo istioctl installed"
  fi
else
  warn "Solo istioctl skipped: repo not yet at $REPO_DIR"
  warn "After scp'ing the repo: bash $REPO_DIR/scripts/install-prereqs.sh --install"
fi

# ── Done ────────────────────────────────────────────────────────────────────
cat <<EOF

──────────────────────────────────────────────────────────────────────
 All prereq tools installed.
──────────────────────────────────────────────────────────────────────

Next steps (interactive, one-time per host):

  1. Pick up the docker group (if you weren't in it already):

       exit
       ssh -i ~/.ssh/<your-key>.pem ubuntu@<this-host>
       docker ps           # should NOT need sudo

  2. Authenticate gcloud (no GUI here — opens browser on YOUR laptop):

       gcloud auth login --no-launch-browser
       gcloud config set project developers-369321
       gcloud auth configure-docker us-central1-docker.pkg.dev

  3. (Optional) gh login:

       gh auth login

  4. If you haven't yet, scp the repo + secrets from your laptop:

       # from your laptop:
       rsync -avz -e "ssh -i ~/.ssh/<key>.pem" --exclude '.claude' \\
         ~/code/solo/solo-labs ~/code/solo/secrets \\
         ubuntu@<this-host>:~/code/solo/

       # then on this host, install the Solo istioctl that was skipped above:
       bash $REPO_DIR/scripts/install-prereqs.sh --install

  5. Run the agentgateway nightly demo:

       cd $REPO_DIR
       export SECRETS_FILE=\$HOME/code/solo/secrets/secrets-envs.sh
       AGW_NIGHTLY=true ./agentgw-multi-cluster-kind/scripts/quick.sh

  6. For the rugpull-demo only — extra env vars before running it:

       export ANTHROPIC_API_KEY=sk-ant-...   # required by every agent
       # (no other rugpull-specific secrets — pyyaml is already installed)

──────────────────────────────────────────────────────────────────────
EOF
