#!/usr/bin/env bash
# 00-cluster.sh — create the GKE Autopilot cluster this lab installs onto.
#
# The rest of the lab starts from a cluster you already have; this is the one
# script that makes one, so the whole thing can run from nothing. Everything it
# does is a single gcloud command plus the waiting, and the command is printed
# before it runs so you can copy it instead of using this script at all.
#
# Autopilot is the point: this lab exists because Istio ambient needs two
# privileged DaemonSets and Autopilot refuses privileged workloads by default.
# Nothing here enables that -- the allowlist steps (02..05) do.
#
#   CLUSTER=my-autopilot REGION=europe-west4 PROJECT=my-project ./00-cluster.sh
set -uo pipefail

CLUSTER="${CLUSTER:?set CLUSTER}"
REGION="${REGION:?set REGION}"
PROJECT="${PROJECT:?set PROJECT}"
CHANNEL="${RELEASE_CHANNEL:-regular}"

die() { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[32m  ok\033[0m %s\n' "$*"; }
step(){ printf '\n\033[36m==>\033[0m %s\n' "$*"; }

command -v gcloud  >/dev/null || die "gcloud not found"
command -v kubectl >/dev/null || die "kubectl not found"

if gcloud container clusters describe "$CLUSTER" --location "$REGION" \
     --project "$PROJECT" >/dev/null 2>&1; then
  ok "cluster $CLUSTER already exists in $REGION"
else
  step "Creating the Autopilot cluster (this takes ~10 minutes)"
  cat <<CMD
    gcloud container clusters create-auto "$CLUSTER" \\
      --location "$REGION" --project "$PROJECT" \\
      --release-channel "$CHANNEL"
CMD
  gcloud container clusters create-auto "$CLUSTER" \
    --location "$REGION" --project "$PROJECT" \
    --release-channel "$CHANNEL" \
    || die "cluster creation failed"
  ok "cluster created"
fi

step "Fetching credentials"
gcloud container clusters get-credentials "$CLUSTER" \
  --location "$REGION" --project "$PROJECT" >/dev/null 2>&1 \
  || die "could not fetch credentials"
kubectl version -o json >/dev/null 2>&1 || die "cluster is not reachable"
ok "kubectl context: $(kubectl config current-context)"

step "What you have"
kubectl get nodes -o custom-columns='NODE:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion' 2>/dev/null | head -5
cat <<'NEXT'

  Autopilot will refuse istio-cni and ztunnel until an allowlist is installed.
  That is the whole exercise. Next:

    ./generate-allowlists.sh     generate them from a Warden refusal
    (then upload, authorise on the org policy AND the cluster, synchronise)
    ./install-ambient.sh         install Istio once the allowlists are in
    ./health-check.sh            prove it actually enforces something
NEXT
