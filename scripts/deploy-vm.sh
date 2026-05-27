#!/usr/bin/env bash
# deploy-vm.sh — provision (or destroy) an EC2 instance and have the Solo
# agentgateway + Istio Ambient kind demo prepped on it end-to-end. Self-
# contained: the prereq bootstrap (docker, kind, kubectl, helm, gcloud, gh,
# meshctl, Solo istioctl + PATH wiring) is embedded as a heredoc inside this
# file, so no other scripts need to be present.
#
# Defaults (all overridable via env):
#   AWS_PROFILE              whatever your shell has set (no script default)
#   REGION                   eu-west-2
#   INSTANCE_TYPE            m6i.2xlarge  (8 vCPU / 32 GiB)
#   AMI                      latest Ubuntu 24.04 amd64 (auto-resolved)
#   ROOT_VOLUME_GB           50 GiB gp3
#   PEM_PATH / KEY_NAME      ~/.ssh/solo-demo.pem  (imported as "solo-demo" key pair on first run)
#   SG_NAME                  solo-demo-ssh-open  (inbound :22 from 0.0.0.0/0 — demo only)
#   NAME_TAG                 solo-demo-<timestamp>
#   REPO_SRC                 ~/code/solo/solo-demos  (rsynced to ~/code/solo/ on the VM)
#   SECRETS_SRC              ~/code/solo/secrets     (rsynced alongside)
#
# Override examples:
#   AWS_PROFILE=my-profile REGION=us-east-1 ./deploy-vm.sh
#   PEM_PATH=~/.ssh/my-key.pem KEY_NAME=my-key ./deploy-vm.sh
#
# Usage:
#   ./deploy-vm.sh             # create + bootstrap + rsync repo+secrets
#   ./deploy-vm.sh prep <ip>   # re-run bootstrap + rsync against an existing IP
#   ./deploy-vm.sh destroy     # terminate every instance tagged solo-demo-*
#   ./deploy-vm.sh status      # list solo-demo-* instances
#   ./deploy-vm.sh ssh         # print the ssh command for the latest one
#
# Skip the auto-prep with NO_PREP=1 ./deploy-vm.sh (instance only, no software).
#
# Cost reminder: m6i.2xlarge in eu-west-2 is ~$0.40/hr (~$10/day). Run destroy
# when you're done.

set -Eeuo pipefail

# ── tunable knobs ────────────────────────────────────────────────────────────
REGION="${REGION:-eu-west-2}"
PROFILE="${AWS_PROFILE:-}"   # whatever your shell has set; empty = AWS CLI default
INSTANCE_TYPE="${INSTANCE_TYPE:-m6i.2xlarge}"
KEY_NAME="${KEY_NAME:-solo-demo}"
PEM_PATH="${PEM_PATH:-$HOME/.ssh/solo-demo.pem}"
SG_NAME="${SG_NAME:-solo-demo-ssh-open}"
NAME_TAG="${NAME_TAG:-solo-demo-$(date +%Y%m%d-%H%M)}"
ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-50}"
AMI_ID="${AMI_ID:-}"
PROJECT_TAG="solo-demo"
REPO_SRC="${REPO_SRC:-$HOME/code/solo/solo-demos}"
SECRETS_SRC="${SECRETS_SRC:-$HOME/code/solo/secrets}"
NO_PREP="${NO_PREP:-0}"

export AWS_PROFILE="$PROFILE"
export AWS_DEFAULT_REGION="$REGION"

ACTION="${1:-up}"

# ── output helpers ───────────────────────────────────────────────────────────
step() { printf '\n══> %s\n' "$*" >&2; }
log()  { printf '   • %s\n' "$*" >&2; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*" >&2; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[31mERROR\033[0m: %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "$1 not in PATH"; }

# ── prereq checks (on this Mac) ──────────────────────────────────────────────
require aws
require ssh-keygen
require jq
require rsync

# ── helpers (idempotent ensure_* pattern) ────────────────────────────────────

ensure_key_pair() {
  step "Key pair: $KEY_NAME"
  if aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    ok "key pair '$KEY_NAME' already exists in AWS"
    return
  fi
  [[ -f "$PEM_PATH" ]] || die "no local key at $PEM_PATH — generate one (ssh-keygen -t rsa -f $PEM_PATH) or set PEM_PATH=..."
  log "importing public key from $PEM_PATH as '$KEY_NAME'"
  local pubkey
  pubkey="$(ssh-keygen -y -f "$PEM_PATH")"
  aws ec2 import-key-pair \
    --key-name "$KEY_NAME" \
    --public-key-material "$(printf '%s' "$pubkey" | base64)" >/dev/null
  ok "key pair imported"
}

ensure_security_group() {
  step "Security group: $SG_NAME (inbound :22 from 0.0.0.0/0)"
  # Declare locals BEFORE the assignment — bash `set -e` doesn't kick in on
  # a failing command-substitution if the declaration is `local var=$(...)`
  # because `local` itself always returns 0, masking the inner failure.
  local vpc_id sg_id
  vpc_id="$(aws ec2 describe-vpcs --filters 'Name=is-default,Values=true' --query 'Vpcs[0].VpcId' --output text)"
  [[ "$vpc_id" != "None" && -n "$vpc_id" ]] || die "no default VPC found in $REGION"
  sg_id="$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$vpc_id" \
            --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  if [[ -n "$sg_id" && "$sg_id" != "None" ]]; then
    ok "security group '$SG_NAME' exists: $sg_id"
  else
    log "creating security group in $vpc_id"
    # Description must be ASCII-only (AWS rejects multi-byte chars).
    sg_id="$(aws ec2 create-security-group \
              --group-name "$SG_NAME" \
              --description "Solo demo - SSH open from 0.0.0.0/0 (demo only)" \
              --vpc-id "$vpc_id" \
              --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJECT_TAG}]" \
              --query 'GroupId' --output text)"
    [[ -n "$sg_id" && "$sg_id" != "None" ]] || die "create-security-group failed (see error above)"
    aws ec2 authorize-security-group-ingress \
      --group-id "$sg_id" \
      --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
    ok "security group created: $sg_id"
  fi
  printf '%s' "$sg_id"
}

resolve_ami() {
  if [[ -n "$AMI_ID" ]]; then echo "$AMI_ID"; return; fi
  aws ec2 describe-images \
    --owners 099720109477 \
    --filters \
      'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
      'Name=state,Values=available' \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text
}

# ── embedded bootstrap script (run on the VM via ssh) ────────────────────────
# This is the same content as scripts/bootstrap-linux.sh in the solo-demos
# repo. Embedding makes this script self-contained — works even if you scp
# only this single file. Keep them in sync if you change one.
embedded_bootstrap_script() {
cat <<'BOOTSTRAP_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

KIND_VERSION="${KIND_VERSION:-v0.31.0}"
MESHCTL_VERSION="${MESHCTL_VERSION:-v2.12.3}"
REPO_DIR="${REPO_DIR:-$HOME/code/solo/solo-demos}"

step() { printf '\n══> %s\n' "$*"; }
log()  { printf '   • %s\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[31mERROR\033[0m: %s\n' "$*" >&2; exit 1; }

[[ -r /etc/os-release ]] || die "/etc/os-release missing — unknown distro"
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "ubuntu/debian only (detected ID=${ID:-unknown})" ;;
esac
USER_NAME="${USER:-$(whoami)}"

step "System basics (curl, jq, openssl, gnupg, wget, python3 + pip)"
sudo apt-get update -qq
sudo apt-get install -y -qq curl jq openssl ca-certificates gnupg wget python3 python3-pip file
ok "basics installed"

# pyyaml — rugpull-demo's observability scripts need it. Cheap to install
# once here vs. each script lazily pip-installing on first run.
if ! python3 -c 'import yaml' 2>/dev/null; then
  log "installing pyyaml"
  pip3 install --quiet --break-system-packages pyyaml 2>/dev/null \
    || pip3 install --quiet pyyaml 2>/dev/null \
    || sudo apt-get install -y -qq python3-yaml 2>/dev/null \
    || warn "pyyaml install failed — rugpull-demo observability scripts may error"
fi
python3 -c 'import yaml' 2>/dev/null && ok "pyyaml available" || true

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

# Kernel limits — default Ubuntu inotify limits exhaust around 2 kind
# clusters, second worker kubelet hangs at TLS bootstrap. Refs:
# https://kind.sigs.k8s.io/docs/user/known-issues/#pod-errors-due-to-too-many-open-files
step "Kernel limits for kind multi-cluster"
sudo tee /etc/sysctl.d/99-kind-multi.conf >/dev/null <<'SYSCTL_EOF'
fs.inotify.max_user_watches   = 524288
fs.inotify.max_user_instances = 512
fs.file-max                   = 2097152
SYSCTL_EOF
sudo sysctl --system >/dev/null 2>&1 || true
ok "inotify + file-max limits raised"

step "kind ($KIND_VERSION)"
CURRENT_KIND="$(kind --version 2>/dev/null | awk '{print $3}' || true)"
if [[ "$CURRENT_KIND" == "${KIND_VERSION#v}" ]]; then
  ok "kind already at ${KIND_VERSION#v}"
else
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
  sudo install -m 0755 /tmp/kind /usr/local/bin/kind && rm /tmp/kind
  ok "kind installed: $(kind --version)"
fi

step "kubectl"
if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl already present"
else
  KCT_VER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KCT_VER}/bin/linux/amd64/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl && rm /tmp/kubectl
  ok "kubectl ${KCT_VER} installed"
fi

step "helm"
if command -v helm >/dev/null 2>&1; then
  ok "helm already present: $(helm version --short)"
else
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ok "helm installed"
fi

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

step "meshctl ($MESHCTL_VERSION)"
if [[ -x "$HOME/.gloo-mesh/bin/meshctl" ]] || command -v meshctl >/dev/null 2>&1; then
  ok "meshctl already installed (~/.gloo-mesh/bin)"
else
  curl -fsSL https://run.solo.io/meshctl/install -o /tmp/meshctl-install.sh
  GLOO_MESH_VERSION="$MESHCTL_VERSION" sh /tmp/meshctl-install.sh
  rm -f /tmp/meshctl-install.sh
  ok "meshctl installed (~/.gloo-mesh/bin)"
fi

step "PATH wiring in ~/.bashrc"
BRC="$HOME/.bashrc"
touch "$BRC"
add_path_line() {
  local line="$1"
  grep -Fqx "$line" "$BRC" || { echo "$line" >> "$BRC"; log "added: $line"; }
}
add_path_line 'export PATH="$HOME/.istioctl/bin:$PATH"'
add_path_line 'export PATH="$HOME/.gloo-mesh/bin:$PATH"'
ok "PATH lines present in ~/.bashrc"

step "Solo istioctl"
if [[ -x "$HOME/.istioctl/bin/istioctl" ]]; then
  ok "Solo istioctl already installed (~/.istioctl/bin)"
elif [[ -x "$REPO_DIR/scripts/install-prereqs.sh" ]]; then
  log "delegating to $REPO_DIR/scripts/install-prereqs.sh --install"
  ( cd "$REPO_DIR" && bash scripts/install-prereqs.sh --install ) || warn "install-prereqs.sh reported errors — review above"
  [[ -x "$HOME/.istioctl/bin/istioctl" ]] && ok "Solo istioctl installed"
else
  warn "Solo istioctl skipped: repo not yet at $REPO_DIR"
  warn "After scp'ing the repo: bash $REPO_DIR/scripts/install-prereqs.sh --install"
fi

echo ""
echo "──────────────────────────────────────────────────────────────────────"
echo " Bootstrap complete on this host."
echo "──────────────────────────────────────────────────────────────────────"
BOOTSTRAP_EOF
}

# ── prep_host: wait for ssh, rsync repo+secrets, run embedded bootstrap ──────

prep_host() {
  local ip="$1"
  local ssh_opts=(-i "$PEM_PATH" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

  step "Waiting for SSH on $ip (up to ~3 min)"
  local i=0
  while (( i < 36 )); do
    if ssh "${ssh_opts[@]}" -o ConnectTimeout=5 "ubuntu@$ip" true 2>/dev/null; then
      ok "ssh ready"
      break
    fi
    sleep 5; i=$(( i+1 ))
  done
  (( i < 36 )) || die "ssh never became reachable at $ip"

  if [[ -d "$REPO_SRC" && -d "$SECRETS_SRC" ]]; then
    step "rsync repo + secrets → $ip:~/code/solo/"
    ssh "${ssh_opts[@]}" "ubuntu@$ip" 'mkdir -p /home/ubuntu/code/solo'
    rsync -az -e "ssh ${ssh_opts[*]}" \
      --exclude '.claude' --exclude '.DS_Store' --exclude 'node_modules' \
      "$REPO_SRC" "$SECRETS_SRC" \
      "ubuntu@$ip:/home/ubuntu/code/solo/"
    ok "repo + secrets synced"
  else
    warn "skipped rsync — REPO_SRC ($REPO_SRC) or SECRETS_SRC ($SECRETS_SRC) missing locally"
  fi

  step "Running bootstrap on $ip (~3-5 min first time)"
  embedded_bootstrap_script | ssh "${ssh_opts[@]}" "ubuntu@$ip" 'bash -s'
  ok "bootstrap finished"
}

# ── up ───────────────────────────────────────────────────────────────────────

cmd_up() {
  ensure_key_pair
  local sg_id ami_id
  sg_id="$(ensure_security_group)"
  step "Resolving latest Ubuntu 24.04 AMI"
  ami_id="$(resolve_ami)"
  log "AMI: $ami_id"

  step "Launching EC2 instance"
  log "  name        $NAME_TAG"
  log "  type        $INSTANCE_TYPE"
  log "  region      $REGION"
  log "  key         $KEY_NAME"
  log "  storage     ${ROOT_VOLUME_GB} GiB gp3"
  log "  security    $sg_id (0.0.0.0/0 :22)"

  local instance_id
  instance_id="$(aws ec2 run-instances \
    --image-id "$ami_id" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$sg_id" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$ROOT_VOLUME_GB,VolumeType=gp3,DeleteOnTermination=true}" \
    --metadata-options 'HttpTokens=optional' \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=$NAME_TAG},{Key=Project,Value=$PROJECT_TAG}]" \
      "ResourceType=volume,Tags=[{Key=Project,Value=$PROJECT_TAG}]" \
    --query 'Instances[0].InstanceId' --output text)"
  ok "instance launched: $instance_id"

  step "Waiting for instance to reach 'running'"
  aws ec2 wait instance-running --instance-ids "$instance_id"
  ok "running"

  step "Waiting for status checks (~60-90s)"
  aws ec2 wait instance-status-ok --instance-ids "$instance_id"
  ok "status OK"

  local public_ip
  public_ip="$(aws ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

  if [[ "$NO_PREP" == "1" ]]; then
    log "NO_PREP=1 set — skipping rsync + bootstrap"
  else
    prep_host "$public_ip"
  fi

  cat <<EOF

──────────────────────────────────────────────────────────────────────
 Demo VM ready.

   Name:        $NAME_TAG
   ID:          $instance_id
   Type:        $INSTANCE_TYPE
   Public IP:   $public_ip

 SSH in:
   ssh -i $PEM_PATH ubuntu@$public_ip

 One manual step (interactive — opens browser on YOUR laptop):
   gcloud auth login --no-launch-browser
   gcloud config set project developers-369321
   gcloud auth configure-docker us-central1-docker.pkg.dev

 Run the agentgateway nightly demo:
   cd ~/code/solo/solo-demos
   export SECRETS_FILE=\$HOME/code/solo/secrets/secrets-envs.sh
   AGW_NIGHTLY=true ./agentgw-multi-cluster-kind/scripts/quick.sh

 For the rugpull-demo: also export your Anthropic key:
   export ANTHROPIC_API_KEY=sk-ant-...

 Destroy (cost ~\$0.40/hr while running):
   $0 destroy
──────────────────────────────────────────────────────────────────────
EOF
}

# ── prep (re-run bootstrap on an existing IP) ────────────────────────────────

cmd_prep() {
  local ip="${2:-}"
  [[ -n "$ip" ]] || die "usage: $0 prep <public-ip>"
  prep_host "$ip"
}

# ── status ───────────────────────────────────────────────────────────────────

cmd_status() {
  step "Instances tagged Project=$PROJECT_TAG in $REGION"
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
              'Name=instance-state-name,Values=pending,running,stopping,stopped' \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,PublicIpAddress,Tags[?Key==`Name`]|[0].Value,LaunchTime]' \
    --output table
}

# ── ssh ──────────────────────────────────────────────────────────────────────

cmd_ssh() {
  local public_ip
  public_ip="$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
              'Name=instance-state-name,Values=running' \
    --query 'reverse(sort_by(Reservations[].Instances[],&LaunchTime))[0].PublicIpAddress' \
    --output text)"
  [[ -n "$public_ip" && "$public_ip" != "None" ]] \
    || die "no running solo-demo instance found in $REGION"
  echo "ssh -i $PEM_PATH ubuntu@$public_ip"
}

# ── destroy ──────────────────────────────────────────────────────────────────

cmd_destroy() {
  step "Finding instances tagged Project=$PROJECT_TAG"
  local ids
  ids="$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
              'Name=instance-state-name,Values=pending,running,stopping,stopped' \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  if [[ -z "$ids" ]]; then
    ok "nothing to destroy"
    return
  fi
  log "terminating: $ids"
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --instance-ids $ids >/dev/null
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --instance-ids $ids
  ok "terminated"
  log "kept: security group '$SG_NAME' + key pair '$KEY_NAME' for next deploy"
  log "  (to also remove: aws ec2 delete-security-group --group-name $SG_NAME; aws ec2 delete-key-pair --key-name $KEY_NAME)"
}

# ── main ─────────────────────────────────────────────────────────────────────

case "$ACTION" in
  up|create|deploy) cmd_up ;;
  prep|provision)   cmd_prep "$@" ;;
  destroy|down|terminate) cmd_destroy ;;
  status|ls|list)   cmd_status ;;
  ssh)              cmd_ssh ;;
  *) die "unknown action '$ACTION' — use: up | prep <ip> | destroy | status | ssh" ;;
esac
