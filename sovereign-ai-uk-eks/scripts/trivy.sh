#!/usr/bin/env bash
# Vulnerability scanning: refuse images with known-critical CVEs at admission.
#
# trivy-operator scans every workload image in the target namespaces and writes a
# VulnerabilityReport; yaml/82-trivy-cve-gate.yaml is the Kyverno policy that reads those
# reports and refuses a pod whose image carries a fixable critical CVE. Together they are the
# prevention control the incident lacked (an unpatched kernel CVE plus unknown registry CVEs),
# next to gVisor for containment and cosign for provenance.
#
#   ./scripts/trivy.sh up      install trivy-operator (scoped) + the CVE gate policy
#   ./scripts/trivy.sh report  show the critical/high counts per scanned workload
#   ./scripts/trivy.sh down    remove trivy-operator (leaves the policy)
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2; CLUSTER=uk-sovereign-ai
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kc() { command kubectl --context "$CTX" "$@"; }

up() {
  helm repo add aqua https://aquasecurity.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update aqua >/dev/null 2>&1
  echo "==> trivy-operator, scoped to the workload namespaces, ignoreUnfixed"
  # Scoped and rate-limited on purpose: an unscoped operator spawns a scan job per workload
  # cluster-wide, which is a lot of load on a shared cluster. ignoreUnfixed keeps the gate to
  # CVEs that actually have a fix. trivy's own DB is pulled from ghcr.io, which the DNS
  # allowlist and restrict-registries both permit; once the ECR mirror cutover is on, it comes
  # from in-region like everything else.
  helm --kube-context "$CTX" upgrade --install trivy-operator aqua/trivy-operator \
    -n trivy-system --create-namespace \
    --set "targetNamespaces=models\,apps\,agents\,kagent" \
    --set trivy.ignoreUnfixed=true \
    --set operator.scanJobsConcurrentLimit=2 --wait --timeout 5m >/dev/null
  echo "==> CVE gate policy (Audit; flip to Enforce once the namespaces are scanned)"
  kc apply -f "$HERE/yaml/82-trivy-cve-gate.yaml" >/dev/null
  echo "    installed. Reports appear a few minutes after each workload is scanned: $0 report"
}

report() {
  kc get vulnerabilityreports.aquasecurity.github.io -A \
    -o custom-columns='NS:.metadata.namespace,WORKLOAD:.metadata.name,CRIT:.report.summary.criticalCount,HIGH:.report.summary.highCount' 2>/dev/null \
    | head -30 || echo "  no reports yet (trivy-operator not installed, or first scan pending)"
}

down() { helm --kube-context "$CTX" uninstall trivy-operator -n trivy-system >/dev/null 2>&1 || true; echo "trivy-operator removed; the CVE gate policy is left in place"; }

case "${1:-up}" in
  up) up ;;
  report) report ;;
  down) down ;;
  *) echo "usage: $0 {up|report|down}"; exit 1 ;;
esac
