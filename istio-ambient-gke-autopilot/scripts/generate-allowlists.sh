#!/usr/bin/env bash
# generate-allowlists.sh — generate the WorkloadAllowlists GKE Autopilot needs in
# order to admit istio-cni and ztunnel.
#
# You do not hand-write these. GKE writes them: annotate the pod template with
#   cloud.google.com/generate-allowlist: "true"
# and Warden returns the exact WorkloadAllowlist for that workload appended to
# its rejection message. A server-side dry-run is enough, so this changes nothing
# in the cluster.
#
# The generated allowlist pins each container by image and matches its args, env
# var names and securityContext exactly, so it MUST be regenerated for every
# Istio version bump and for any change to the Helm values used at install time.
# That is what this script is for. Keep the values below in step with
# install-ambient.sh.
#
# Nothing here needs write access to the cluster or the bucket.
set -uo pipefail

ISTIO_VER="${ISTIO_VER:-1.30.4}"
OUT="${OUT:-./allowlists}"

# --- the four values you have to set -----------------------------------------
#
# profile=ambient changes ztunnel's image to :TAG-distroless and adds
# ISTIO_META_ENABLE_HBONE, so an allowlist generated without it is silently
# rejected.
ISTIO_PROFILE="${ISTIO_PROFILE:-ambient}"
#
# global.platform=gke ships the ResourceQuota that lets the system-node-critical
# priority class run in istio-system. In 1.30.4 that is ALL it does; in
# particular it does not fix the CNI directory below.
ISTIO_PLATFORM="${ISTIO_PLATFORM:-gke}"
#
# Container-Optimized OS mounts /opt/cni/bin read-only, so the chart default
# makes istio-cni crash-loop with "read-only file system" AFTER passing
# admission. This changes the rendered hostPath and therefore the allowlist.
ISTIO_CNI_BIN_DIR="${ISTIO_CNI_BIN_DIR:-/home/kubernetes/bin}"
#
# The single most important value here. By default the cni chart requests
# AppArmor with the deprecated annotation
#   container.apparmor.security.beta.kubernetes.io/install-cni: unconfined
# and GKE's allowlist generator does NOT emit appArmorProfile for that form. The
# allowlist then never matches, and admission fails citing the ORIGINAL
# capability and hostPath violations with nothing pointing at AppArmor. Setting
# this false makes the chart use securityContext.appArmorProfile, which the
# generator does read. Needs Kubernetes 1.30+.
ISTIO_APPARMOR_ANNOTATION="${ISTIO_APPARMOR_ANNOTATION:-false}"
# -----------------------------------------------------------------------------

die() { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[32m  ok\033[0m %s\n' "$*"; }
warn(){ printf '\033[33mwarn\033[0m %s\n' "$*" >&2; }
step(){ printf '\n\033[36m==>\033[0m %s\n' "$*"; }

command -v helm    >/dev/null || die "helm not found"
command -v kubectl >/dev/null || die "kubectl not found"
kubectl version -o json >/dev/null 2>&1 || die "cannot reach the cluster; check your kubeconfig context"

# BSD sed needs an argument to -i, GNU sed must not have one. Decide once:
# trying one and falling back to the other on failure can leave a file named ''.
if sed --version >/dev/null 2>&1; then SED_INPLACE=(-i); else SED_INPLACE=(-i ''); fi

mkdir -p "$OUT"
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update istio >/dev/null 2>&1 || true

for CHART in cni ztunnel; do
  NAME="istio-$CHART"
  step "Generating the allowlist for $NAME $ISTIO_VER"
  NEW="$OUT/.$NAME.new"

  # Both charts expose podAnnotations, so the generate-allowlist annotation goes
  # in with --set and needs no YAML editing. --set-string matters: plain --set
  # renders true as a boolean and the annotation is then invalid.
  #
  # cni.* values are ignored by the ztunnel chart and vice versa, so passing the
  # union to both is harmless and keeps this loop simple.
  #
  # --dry-run=server is essential. --dry-run=client never reaches the webhook
  # and produces nothing.
  # Render to a file first rather than straight into the pipe. If helm fails --
  # no repo, a bad --version, a values error -- the pipeline still succeeds with
  # empty input, and the empty result below would be read as "Warden admitted
  # it". That is the exact opposite of what happened, so separate the two.
  RENDER="$OUT/.$NAME.rendered"
  if ! helm template "istio-$CHART" "istio/$CHART" --version "$ISTIO_VER" \
      -n istio-system \
      --set profile="$ISTIO_PROFILE" \
      --set global.platform="$ISTIO_PLATFORM" \
      --set cni.cniBinDir="$ISTIO_CNI_BIN_DIR" \
      --set cni.useAppArmorAnnotation="$ISTIO_APPARMOR_ANNOTATION" \
      --set-string cni.podAnnotations."cloud\.google\.com/generate-allowlist"=true \
      --set-string podAnnotations."cloud\.google\.com/generate-allowlist"=true \
      > "$RENDER" 2>"$RENDER.err"; then
    warn "helm template failed for istio/$CHART $ISTIO_VER:"
    sed 's/^/    /' "$RENDER.err" >&2
    rm -f "$RENDER" "$RENDER.err"
    die "could not render the chart, so no allowlist could be generated"
  fi
  rm -f "$RENDER.err"

  kubectl apply --dry-run=server -f "$RENDER" 2>&1 \
    | sed -n '/^apiVersion: auto.gke.io/,$p' > "$NEW"
  rm -f "$RENDER"

  if [[ ! -s "$NEW" ]]; then
    # An empty result means the dry-run was ADMITTED, so Warden emitted nothing.
    # That normally means an allowlist for this workload is already installed.
    # Do not overwrite the existing file: it is very likely the one making that
    # true. Staging to a temp file first is what makes this safe.
    warn "$NAME: nothing emitted, so the workload was admitted. Keeping the existing file."
    [[ -s "$OUT/$NAME.yaml" ]] || warn "  and there is no previous file for $NAME"
    rm -f "$NEW"
    continue
  fi

  # GKE timestamps the allowlist name, so a regeneration would install a SECOND
  # allowlist rather than replacing the first. Give it a stable name.
  sed "${SED_INPLACE[@]}" "s|^\\( *\\)name: allowlist-[0-9a-zt.-]*\$|\\1name: $NAME-$ISTIO_VER|" "$NEW"

  mv "$NEW" "$OUT/$NAME.yaml"
  ok "wrote $OUT/$NAME.yaml"
  printf '     exemptions: %s\n' \
    "$(grep -A4 '^exemptions:' "$OUT/$NAME.yaml" | grep '^\s*-' | tr -d ' -' | tr '\n' ' ')"

  if [[ "$CHART" == "cni" ]]; then
    if grep -q 'appArmorProfile' "$OUT/$NAME.yaml"; then
      ok "appArmorProfile present, so the generator read it from securityContext"
    else
      warn "appArmorProfile MISSING. This allowlist will never match. Re-run with"
      warn "  ISTIO_APPARMOR_ANNOTATION=false"
    fi
    grep -q '/home/kubernetes/bin' "$OUT/$NAME.yaml" \
      || warn "cni-bin-dir is not /home/kubernetes/bin; istio-cni will crash-loop after admission"
  fi
done

step "Next"
cat <<'NEXT'
  1. Upload, keeping these exact object names:
       gcloud storage cp ./allowlists/istio-cni.yaml \
         "gs://${BUCKET}/istio/${ISTIO_VER}/istio-cni.yaml"
       gcloud storage cp ./allowlists/istio-ztunnel.yaml \
         "gs://${BUCKET}/istio/${ISTIO_VER}/istio-ztunnel.yaml"
  2. Add both gs:// paths to the container.managed.autopilotPrivilegedAdmission
     org policy   (yaml/01-orgpolicy-autopilot-privileged-admission.yaml)
  3. Add them to the cluster's --autopilot-privileged-admission, keeping gke://*
  4. Apply the synchroniser  (yaml/02-allowlistsynchronizer.yaml)
  5. ./install-ambient.sh
NEXT
