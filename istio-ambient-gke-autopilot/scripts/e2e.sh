#!/usr/bin/env bash
# e2e.sh — the whole lab, from no cluster to proven L4/L7 enforcement.
#
# Every step here is also a plain command in the README, and the README is the
# better way to LEARN this: read it, run the commands, understand why each one
# is there. This script exists so you can (a) get a working environment quickly
# and (b) check the sequence still works after an Istio bump.
#
# The order is not arbitrary. Autopilot refuses istio-cni and ztunnel, and the
# only way through is a WorkloadAllowlist that GKE itself generates from a
# Warden refusal. That allowlist pins the container IMAGE and matches args, env
# names and securityContext EXACTLY, so it has to be generated with the same
# Helm values used to install, and re-generated for every version bump. Hence:
#
#   0. cluster
#   1. bucket + the GKE service-agent grant people miss
#   2. generate the allowlists from a server-side dry-run
#   3. upload them, naming each object in full
#   4. authorise those exact paths on the org policy AND on the cluster
#      (~20 min, and it fails once on propagation -- expected)
#   5. AllowlistSynchronizer, then wait for them to appear
#   6. quota + Istio
#   7. enrol, waypoint, prove it enforces
#
# Required: CLUSTER REGION PROJECT ORG_ID PROJECT_NUMBER BUCKET
set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML="$SD/../yaml"

: "${CLUSTER:?}" "${REGION:?}" "${PROJECT:?}" "${ORG_ID:?}" "${PROJECT_NUMBER:?}" "${BUCKET:?}"
ISTIO_VER="${ISTIO_VER:-1.30.4}"
export CLUSTER REGION PROJECT ORG_ID PROJECT_NUMBER BUCKET ISTIO_VER

die() { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[32m  ok\033[0m %s\n' "$*"; }
hdr() { printf '\n\033[1;34m══ %s\033[0m\n' "$*"; }

command -v envsubst >/dev/null || die "envsubst not found (brew install gettext)"

hdr "0. Autopilot cluster"
"$SD/00-cluster.sh" || die "cluster step failed"

hdr "1. allowlist bucket and the GKE service-agent grant"
# The synchroniser reads the bucket as the GKE SERVICE AGENT, not as you.
# Miss this grant and it reports an error that reads like an org policy problem.
gcloud storage buckets describe "gs://${BUCKET}" >/dev/null 2>&1 \
  || gcloud storage buckets create "gs://${BUCKET}" --location "$REGION" --project "$PROJECT" \
  || die "could not create gs://${BUCKET}"
AGENT="service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${AGENT}" --role=roles/storage.admin >/dev/null 2>&1 \
  || die "could not grant roles/storage.admin to ${AGENT}"
ok "bucket ready, ${AGENT} can read it"

hdr "2. generate the allowlists"
( cd "$SD" && ./generate-allowlists.sh ) || die "allowlist generation failed"

hdr "3. upload, naming each object in full"
for f in istio-cni istio-ztunnel; do
  gcloud storage cp "$SD/allowlists/${f}.yaml" \
    "gs://${BUCKET}/istio/${ISTIO_VER}/${f}.yaml" >/dev/null \
    || die "upload of ${f}.yaml failed"
done
ok "uploaded to gs://${BUCKET}/istio/${ISTIO_VER}/"

hdr "4. authorise the paths (org policy, then the cluster)"
# A trailing-slash directory prefix is ACCEPTED here and then refused at step 5:
# the check is exact string membership. Name every object.
envsubst < "$YAML/01-orgpolicy-autopilot-privileged-admission.yaml" > /tmp/policy.yaml
gcloud org-policies set-policy /tmp/policy.yaml >/dev/null || die "org policy failed"
ok "org policy updated"

PATHS="gke://*"
for f in istio-cni istio-ztunnel; do
  PATHS="${PATHS},gs://${BUCKET}/istio/${ISTIO_VER}/${f}.yaml"
done
# A cluster will not accept an update while another operation is in flight:
#   FAILED_PRECONDITION: Cluster is running incompatible operation <id>
# Straight after creation that is the normal state, not an error, so wait for
# RUNNING rather than failing the run.
wait_cluster_running() {
  local i st
  for i in $(seq 1 60); do
    st="$(gcloud container clusters describe "$CLUSTER" --location "$REGION" \
          --project "$PROJECT" --format='value(status)' 2>/dev/null)"
    [[ "$st" == "RUNNING" ]] && return 0
    [[ "$i" -eq 1 ]] && echo "    cluster is $st; waiting for it to settle"
    sleep 30
  done
  return 1
}
wait_cluster_running || echo "    still not RUNNING; trying the update anyway"

echo "    ~20 minutes, and the first attempt usually fails on propagation"
for attempt in 1 2 3 4; do
  if gcloud container clusters update "$CLUSTER" --location "$REGION" --project "$PROJECT" \
       --autopilot-privileged-admission="$PATHS" 2>/tmp/upd.err; then
    ok "cluster authorises the allowlist paths"; break
  fi
  if grep -q 'CUSTOM_ORG_POLICY_DENIED\|propagat' /tmp/upd.err 2>/dev/null; then
    echo "    attempt $attempt hit org-policy propagation; waiting 120s"
    sleep 120
    continue
  fi
  # GKE runs its own maintenance operations, so this race cannot be removed,
  # only waited out.
  if grep -qE 'running incompatible operation|FAILED_PRECONDITION' /tmp/upd.err 2>/dev/null; then
    echo "    attempt $attempt found the cluster busy; waiting for it to finish"
    wait_cluster_running || true
    continue
  fi
  sed 's/^/    /' /tmp/upd.err >&2
  die "cluster update failed"
done

hdr "5. AllowlistSynchronizer"
envsubst < "$YAML/02-allowlistsynchronizer.yaml" | kubectl apply -f - >/dev/null \
  || die "could not apply the synchroniser"
echo "    GKE re-reads the bucket every 10 minutes; waiting for the objects"
for _ in $(seq 1 40); do
  n=$(kubectl get workloadallowlists --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "${n:-0}" -ge 2 ]] && break
  sleep 20
done
if [[ "${n:-0}" -lt 2 ]]; then
  kubectl get allowlistsynchronizer -o yaml 2>/dev/null | sed -n '/^status:/,$p' | head -20 >&2
  die "allowlists never appeared — the synchroniser status is above"
fi
ok "$n WorkloadAllowlists installed"

hdr "6. quota and Istio"
( cd "$SD" && ./install-ambient.sh ) || die "Istio install failed"

hdr "7. enrol, waypoint, test workloads"
kubectl apply -f "$YAML/test/01-ambient-enroll.yaml" >/dev/null
kubectl apply -f "$YAML/test/02-waypoint.yaml"       >/dev/null
kubectl apply -f "$YAML/test/03-test-workloads.yaml" >/dev/null
ok "applied"

hdr "8. prove it enforces something"
( cd "$SD" && ./health-check.sh ) || die "health checks failed"

hdr "DONE"
echo "  Istio ambient is running on GKE Autopilot, with L4 identity policy at"
echo "  ztunnel and L7 method policy at the waypoint, both verified."
