<a id="generated-allowlists--reference-copies-not-inputs"></a>
# Generated allowlists: reference copies, not inputs

These two files are the exact `WorkloadAllowlist` objects GKE Warden emitted on
the verified run (Istio 1.30.4, GKE Autopilot v1.35.6-gke.1049000). They are here
so you can see what a correct one looks like, and diff yours against them.

**Do not upload these as-is.** `matchingCriteria` pins the container image and the
set of env var names, so an allowlist only ever matches the exact workload it was
generated from. Generate your own with `scripts/generate-allowlists.sh` (or step 2
of the write-up), using the same Helm values you install with.

Two things to look for in your own output:

- `appArmorProfile` under `containers[].securityContext` on the istio-cni one. If
  it is missing you rendered without `cni.useAppArmorAnnotation=false`, and the
  allowlist will never match.
- `volumes[].hostPath.path: /home/kubernetes/bin` for `cni-bin-dir`. If it says
  `/opt/cni/bin` you rendered without `cni.cniBinDir`, and istio-cni will
  crash-loop on a read-only filesystem after passing admission.

The `metadata.name` in both files has been changed from the timestamp GKE
generates (`allowlist-2026-09-04t17-44-08`) to a stable name, so a regeneration
replaces the allowlist instead of adding a second one.
