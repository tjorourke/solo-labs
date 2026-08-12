#!/usr/bin/env bash
# The policy layer: Pod Security Admission on every workload namespace, and Kyverno
# for the rules PSA cannot express.
#
#   ./scripts/policy.sh up       PSA labels + Kyverno + the policy set
#   ./scripts/policy.sh test     prove each policy refuses a real violation
#   ./scripts/policy.sh status   what is enforcing, and any recent denials
#   ./scripts/policy.sh down     remove Kyverno (PSA labels stay)
#
# WHY BOTH. PSA is built into the API server and free: one namespace label enforces the
# restricted profile (no privileged, no hostPath, no root, seccomp on). But it is all or
# nothing and pod-only. Kyverno covers what PSA cannot say: image registries, :latest
# tags, token automounting, secrets-in-env, and it can mutate as well as validate.
# Kyverno rather than Gatekeeper because policies stay YAML instead of Rego, which
# matters on a page people are meant to read and copy.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
KYVERNO_VERSION="${KYVERNO_VERSION:-v1.13.4}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The workload namespaces. istio-system, cert-manager, vault and kube-system are
# deliberately absent: ztunnel and istio-cni genuinely need privilege PSA would refuse,
# and the CA path must never be blocked from starting by its own policy layer.
WORKLOAD_NS=(models agentgateway-system keycloak apps)

case "${1:-status}" in
  up)
    echo "==> Pod Security Admission: restricted profile on workload namespaces"
    # warn+audit at restricted, enforce at baseline for agentgateway-system: the
    # gateway data plane needs NET_BIND_SERVICE for :80, which restricted refuses.
    # Everything else enforces restricted outright.
    for ns in "${WORKLOAD_NS[@]}"; do
      kc get ns "$ns" >/dev/null 2>&1 || { echo "    skip $ns (absent)"; continue; }
      if [ "$ns" = "agentgateway-system" ]; then
        kc label ns "$ns" \
          pod-security.kubernetes.io/enforce=baseline \
          pod-security.kubernetes.io/warn=restricted \
          pod-security.kubernetes.io/audit=restricted --overwrite >/dev/null
        echo "    $ns -> enforce=baseline, warn+audit=restricted"
      else
        kc label ns "$ns" \
          pod-security.kubernetes.io/enforce=restricted \
          pod-security.kubernetes.io/warn=restricted --overwrite >/dev/null
        echo "    $ns -> enforce=restricted"
      fi
    done

    echo "==> Kyverno $KYVERNO_VERSION"
    kc apply --server-side -f \
      "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml" >/dev/null
    kc -n kyverno rollout status deploy/kyverno-admission-controller --timeout=300s >/dev/null
    echo "    ok"

    echo "==> the policy set"
    kc apply -f "$LAB_ROOT/yaml/40-policies.yaml"
    # Policies admit in fail-closed mode only once the webhook is Ready; give it a beat.
    sleep 5
    kc get clusterpolicy -o custom-columns='POLICY:.metadata.name,ACTION:.spec.validationFailureAction,READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null
    ;;

  test)
    # A real create, never --dry-run: server dry-run skips some PSA and Kyverno paths,
    # and it was the dry-run, not the policy, that made an earlier version of this
    # harness report NOT REFUSED against policies that were in fact enforcing. Each
    # probe is deleted if it somehow slips through.
    #
    # Ordering matters for what you SEE. PSA runs before Kyverno, so a pod that trips
    # both is refused by PSA first and only its message shows. Each probe below is
    # therefore built to satisfy PSA (non-root, no privilege, seccomp) so that the
    # Kyverno rule under test is the thing that refuses it. The PSA test uses its own
    # deliberately-privileged pod.
    hardened='"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}'
    csec='"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}'

    probe() { # probe <name> <ns> <expect-substring> <json-overrides>
      local name="$1" ns="$2" want="$3" ov="$4" out
      out="$(kc -n "$ns" run "$name" --image=busybox:1.36 --restart=Never --overrides="$ov" --command -- sleep 1 2>&1 || true)"
      kc -n "$ns" delete pod "$name" --ignore-not-found >/dev/null 2>&1
      if printf '%s' "$out" | grep -q "$want"; then
        echo "    REFUSED by: $want"
      else
        echo "    NOT REFUSED (unexpected). Output:"; printf '%s\n' "$out" | sed 's/^/      /' | head -3
      fi
    }

    echo "=== 1. privileged pod in models -> Pod Security Admission"
    probe psa-probe models 'violates PodSecurity' \
      "{\"spec\":{\"containers\":[{\"name\":\"x\",\"image\":\"busybox:1.36\",\"command\":[\"sleep\",\"1\"],\"securityContext\":{\"privileged\":true}}]}}"
    echo
    echo "=== 2. :latest tag in models -> Kyverno disallow-latest-tag"
    probe tag-probe models 'disallow-latest-tag' \
      "{\"spec\":{$hardened,\"containers\":[{\"name\":\"x\",\"image\":\"busybox:latest\",\"command\":[\"sleep\",\"1\"],$csec}]}}"
    echo
    echo "=== 3. unapproved registry -> Kyverno restrict-registries"
    probe reg-probe models 'restrict-registries' \
      "{\"spec\":{$hardened,\"containers\":[{\"name\":\"x\",\"image\":\"evil.example.com/x:1.0\",\"command\":[\"sleep\",\"1\"],$csec}]}}"
    echo
    echo "=== 4. secret in an env var in apps -> Kyverno disallow-secrets-in-env"
    kc get ns apps >/dev/null 2>&1 || kc create ns apps >/dev/null 2>&1
    probe env-probe apps 'disallow-secrets-in-env' \
      "{\"spec\":{$hardened,\"containers\":[{\"name\":\"x\",\"image\":\"busybox:1.36\",\"command\":[\"sleep\",\"1\"],$csec,\"env\":[{\"name\":\"K\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"s\",\"key\":\"k\"}}}]}]}}"
    ;;

  status)
    echo "=== PSA labels"
    kc get ns -L pod-security.kubernetes.io/enforce --no-headers 2>/dev/null | awk '$NF!="<none>" && $NF!="" {print "  "$1" -> "$NF}'
    echo
    echo "=== Kyverno policies"
    kc get clusterpolicy -o custom-columns='POLICY:.metadata.name,ACTION:.spec.validationFailureAction,READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null || echo "  not installed"
    echo
    echo "=== recent denials (the audit trail)"
    kc get events -A --field-selector reason=PolicyViolation --sort-by=.lastTimestamp 2>/dev/null | tail -6
    ;;

  down)
    kc delete -f "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml" >/dev/null 2>&1 || true
    echo "Kyverno removed. PSA labels left in place (they cost nothing and still enforce)."
    ;;

  *) echo "usage: $0 {up|test|status|down}"; exit 1 ;;
esac
