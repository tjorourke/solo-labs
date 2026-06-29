#!/usr/bin/env bash
# Provision a self-managed OpenShift (IPI) cluster on AWS.
# OCP 4.21 ships Gateway API 1.3.0, which is what this lab validates against.
#
# Prereqs: source ../env.sh first (CLUSTER_NAME, BASE_DOMAIN, AWS_REGION,
# PULL_SECRET, OCP_CHANNEL, AWS_ACCESS_KEY_ID/SECRET).
#
# IMPORTANT (credentials): IPI default "mint" mode creates per-operator IAM
# users and therefore needs long-lived credentials. AWS SSO/STS temporary
# creds are rejected with:
#   "AWS credentials provided by SSOProvider are not valid for default
#    credentials mode"
# Workaround: create a dedicated installer IAM user with AdministratorAccess
# and a static access key, put it in env.sh, and delete the user at teardown:
#   aws iam create-user --user-name ocp-installer
#   aws iam attach-user-policy --user-name ocp-installer \
#       --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
#   aws iam create-access-key --user-name ocp-installer
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
: "${CLUSTER_NAME:?}"; : "${BASE_DOMAIN:?}"; : "${AWS_REGION:?}"; : "${PULL_SECRET:?}"
OCP_CHANNEL="${OCP_CHANNEL:-stable-4.21}"
BIN="$HERE/bin"; WORK="$HERE/cluster"; mkdir -p "$BIN"

# --- tooling (openshift-install + oc), matched to your laptop os/arch ---
case "$(uname -s)" in Darwin) OS=mac;; Linux) OS=linux;; esac
case "$(uname -m)" in arm64|aarch64) ARCH=-arm64;; x86_64) ARCH="";; esac
BASE="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_CHANNEL}"
if [ ! -x "$BIN/openshift-install" ]; then
  curl -sSL "$BASE/openshift-install-${OS}${ARCH}.tar.gz" | tar -xz -C "$BIN" openshift-install
  curl -sSL "$BASE/openshift-client-${OS}${ARCH}.tar.gz"  | tar -xz -C "$BIN" oc kubectl
fi
"$BIN/openshift-install" version

# --- ssh key for node debug access ---
[ -f "$HERE/ssh-key" ] || ssh-keygen -t ed25519 -N "" -f "$HERE/ssh-key" -C "$CLUSTER_NAME"

# --- install-config.yaml ---
rm -rf "$WORK"; mkdir -p "$WORK"
PS="$(tr -d '\n' < "$PULL_SECRET")"
SSH="$(cat "$HERE/ssh-key.pub")"
cat > "$WORK/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
controlPlane:
  name: master
  replicas: 3
  platform: { aws: { type: m6i.xlarge, rootVolume: { size: 120, type: gp3 } } }
compute:
- name: worker
  replicas: 2
  platform: { aws: { type: m6i.xlarge, rootVolume: { size: 120, type: gp3 } } }
networking:
  networkType: OVNKubernetes
  machineNetwork: [{ cidr: 10.30.0.0/16 }]
  clusterNetwork: [{ cidr: 10.128.0.0/14, hostPrefix: 23 }]
  serviceNetwork: [172.30.0.0/16]
platform:
  aws: { region: ${AWS_REGION} }
publish: External
pullSecret: '${PS}'
sshKey: '${SSH}'
EOF

# --- create the cluster (~40-45 min) ---
"$BIN/openshift-install" create cluster --dir "$WORK" --log-level=info
echo "kubeconfig: $WORK/auth/kubeconfig"
echo "export KUBECONFIG=$WORK/auth/kubeconfig"
