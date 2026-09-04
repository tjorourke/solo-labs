# Istio ambient on GKE Autopilot

Artifacts for the write-up at
<https://www.masterthemesh.com/solo/istio-ambient-gke-autopilot/>.

The page is the guide: every step is a plain `helm`, `kubectl` or `gcloud`
command, written out. What is here is the same thing as files, for when you
want it in a repo. Nothing here is required in order to follow the page.

Verified on GKE Autopilot `v1.35.6-gke.1049000`, upstream Istio 1.30.4,
2026-09-04.

## The problem, in one paragraph

Autopilot refuses privileged workloads, and Istio ambient is two of them.
`istio-cni` needs `NET_ADMIN`, `NET_RAW`, `SYS_PTRACE`, `SYS_ADMIN` and
`DAC_OVERRIDE` plus write-mode hostPaths; `ztunnel` needs `NET_ADMIN`,
`SYS_ADMIN`, `NET_RAW` and a write-mode hostPath for its socket. Neither runs as
`privileged: true`, so the blockers are Linux capabilities and hostPath rather
than privileged mode.

The route through is Autopilot's privileged workload admission control. GKE
Warden refuses your pod and appends the `WorkloadAllowlist` that would have
admitted it. You upload that to Cloud Storage, authorise the path on the
organisation policy and on the cluster, and an `AllowlistSynchronizer` installs
it. Then the same `helm install` is admitted.

> **Note:** Running your own privileged workloads in Autopilot is available only
> to eligible Google Cloud customers. To check whether you're eligible, contact
> Cloud Customer Care.
> ([Google's reference](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/about-autopilot-privileged-workloads#customer-owned-privileged-workloads))

## Layout

```
yaml/
  00-critical-pods-quota.yaml                     ResourceQuota so istio-system may run
                                                  system-node-critical. Not in Google's docs.
  01-orgpolicy-autopilot-privileged-admission.yaml
                                                  container.managed.autopilotPrivilegedAdmission
  02-allowlistsynchronizer.yaml                   the one you write and apply yourself
  allowlists/                                     the two allowlists GKE generated on the
                                                  verified run. Reference only: diff yours
                                                  against them, do not upload these.
  probe/netadmin-pod.yaml                         smallest privileged pod, to test whether
                                                  customer-owned allowlisting works at all
                                                  in your project before touching Istio
  test/                                           namespace enrolment, waypoint, two client
                                                  identities, L4 and L7 AuthorizationPolicy
scripts/
  generate-allowlists.sh                          step 2 of the write-up
  install-ambient.sh                              steps 6 and 7, with preflight assertions
  health-check.sh                                 step 9, as six pass/fail checks
tofu/
  allowlist-bucket.tf                             the bucket, and the GKE service agent grant
                                                  people miss
```

Standing up the Autopilot cluster is out of scope here. These start from one you
already have.

## Substitutions

The YAML uses `${...}` placeholders rather than real identifiers. Set these and
pipe through `envsubst`:

```bash
export CLUSTER=my-autopilot
export REGION=europe-west4
export PROJECT=my-project
export ORG_ID=123456789012
export PROJECT_NUMBER=210987654321
export BUCKET=my-allowlists
export ISTIO_VER=1.30.4

envsubst < yaml/01-orgpolicy-autopilot-privileged-admission.yaml > /tmp/policy.yaml
gcloud org-policies set-policy /tmp/policy.yaml

envsubst < yaml/02-allowlistsynchronizer.yaml | kubectl apply -f -
```

## Order

```bash
# 1. bucket, plus the grant for the GKE service agent (see tofu/, or the page's step 1)

# 2. generate the allowlists from a Warden refusal, then upload
cd scripts && ./generate-allowlists.sh
gcloud storage cp allowlists/istio-cni.yaml     "gs://${BUCKET}/istio/${ISTIO_VER}/istio-cni.yaml"
gcloud storage cp allowlists/istio-ztunnel.yaml "gs://${BUCKET}/istio/${ISTIO_VER}/istio-ztunnel.yaml"

# 3. org policy, then 4. the cluster flag (this one takes ~20 min and fails once on propagation)
gcloud container clusters update "$CLUSTER" --location "$REGION" \
  --autopilot-privileged-admission="gke://*,gs://${BUCKET}/istio/${ISTIO_VER}/istio-cni.yaml,gs://${BUCKET}/istio/${ISTIO_VER}/istio-ztunnel.yaml"

# 5. the synchroniser, and confirm the allowlists appear
envsubst < yaml/02-allowlistsynchronizer.yaml | kubectl apply -f -
kubectl get workloadallowlists

# 6 + 7. quota and Istio
./install-ambient.sh

# 8 + 9. enrol, waypoint, prove enforcement
kubectl apply -f ../yaml/test/01-ambient-enroll.yaml
kubectl apply -f ../yaml/test/02-waypoint.yaml
kubectl apply -f ../yaml/test/03-test-workloads.yaml
./health-check.sh
```

## The four chart values you have to set

Every one of these must be identical when you generate the allowlist and when
you install, because the first three change the rendered pod spec and the
allowlist matches that spec exactly. `scripts/generate-allowlists.sh` and
`scripts/install-ambient.sh` share their defaults for this reason.

| Value | Without it |
|---|---|
| `profile=ambient` | ztunnel's image and env differ, so the allowlist never matches |
| `global.platform=gke` | no `ResourceQuota` for `system-node-critical`. In 1.30.4 that is all this flag does |
| `cni.cniBinDir=/home/kubernetes/bin` | istio-cni passes admission, then crash-loops on read-only `/opt/cni/bin` |
| `cni.useAppArmorAnnotation=false` | GKE's generator omits `appArmorProfile`, so the allowlist silently never matches |

The last one is the one that costs time. The chart's default AppArmor annotation
is not translated by GKE's allowlist generator, so admission fails citing the
original capability and hostPath violations with nothing pointing at AppArmor.

## What you give up

Pods admitted through a `WorkloadAllowlist` carry
`autopilot.gke.io/no-connect: "true"`, and Warden's `pods/*` `CONNECT` rule then
refuses `kubectl exec` and port-forward into them. So `istioctl ztunnel-config`
and `istioctl proxy-config` do not work against ztunnel here. That is why
`health-check.sh` reads logs and scrapes ztunnel's metrics from another pod
instead. `istiod` and the waypoints are unaffected.
