# Lab: migrate an OpenShift app from the built-in gateway to agentgateway (zero downtime)

This lab provisions a real OpenShift cluster on AWS, runs a sample app behind
OpenShift's own Gateway API implementation, then migrates it live to
agentgateway, all without touching the Gateway API CRDs that OpenShift manages.
It is the validated, hands-on companion to the field guide
[`agentgateway on OpenShift`](../).

Everything here was run end to end on a fresh cluster. The headline result:
**agentgateway runs on OpenShift's cluster-managed Gateway API 1.3.0 with no CRD
changes, coexists with OpenShift's own gateway, and the migration moved live
traffic with zero dropped requests** (`evidence/availability-evidence.log`,
103/103 requests `200`, `fail=0`).

## What was validated

| Claim | Result |
|---|---|
| OpenShift 4.21 ships Gateway API | `v1.3.0`, read off the `bundle-version` annotation on the cluster-managed CRD |
| CRDs are cluster-owned on a fresh install | `gatewayclasses/gateways/httproutes/grpcroutes/referencegrants` present at install time, nobody applied them |
| agentgateway supports that version | installs and serves on 1.3.0, no `standard-install.yaml`, supported range is 1.3-1.5 |
| Coexistence (no controller to disable) | `openshift-default` and `enterprise-agentgateway` GatewayClasses both `Accepted=True`, side by side |
| Zero-downtime migration | DNS cutover OpenShift-gw -> agentgateway, `fail=0` across the flip |
| agentgateway below the floor (OCP 4.20, GW API 1.2.1) | installs and serves core Gateway + HTTPRoute (functional, but **unsupported** and feature-limited) |

Tested builds: **OpenShift 4.21.20** (k8s 1.34, Gateway API 1.3.0), OpenShift
Service Mesh 3.2 / Istio 1.27.3 (auto-installed), **Solo Enterprise for
agentgateway v2026.6.1**.

## Run it

Copy `env.sample` to `env.sh`, fill it in, then:

```
source env.sh
./scripts/00-install-openshift.sh        # ~40-45 min, provisions OCP 4.21 on AWS (IPI)
export KUBECONFIG=$PWD/cluster/auth/kubeconfig
./scripts/01-deploy-sample-app.sh        # app behind OpenShift's own gateway (1.3.0 CRDs)
# start the monitor in the background (set the LB hostnames it prints):
OPENSHIFT_LB=<lb> ./scripts/02-monitor.sh &
./scripts/03-install-agentgateway.sh     # agentgateway against the cluster CRDs (no CRD apply)
AGW_LB=<lb> ./scripts/04-migrate-cutover.sh   # stand up agentgateway, attach route, cut DNS over
./scripts/99-cleanup.sh                   # destroy everything
```

## Findings and gotchas (the things that cost real time)

These are why the lab exists. Each one fails silently or with an unhelpful
message, so they are worth knowing before a customer hits them.

### 1. The AWS credentials mode (install)
IPI's default "mint" mode creates per-operator IAM users and needs long-lived
credentials. AWS **SSO/STS temporary creds are rejected**:
`AWS credentials provided by SSOProvider are not valid for default credentials mode`.
Fix: a dedicated installer IAM user with `AdministratorAccess` + a static access
key (deleted at teardown). See `scripts/00`.

### 2. The GatewayClass controllerName needs the `/v1` suffix
OpenShift's controller is **`openshift.io/gateway-controller/v1`**. Create a
GatewayClass with `openshift.io/gateway-controller` (no `/v1`) and the Ingress
Operator silently ignores it: no OSSM install, no error, `Accepted=Unknown`
forever. With the correct name, the operator creates a `servicemeshoperator3`
OLM subscription and installs Istio automatically.

### 3. OpenShift's gateway only programs Gateways in `openshift-ingress`
A `Gateway` for the `openshift-default` class created in an app namespace stays
`Accepted=Unknown` ("Waiting for controller") with no diagnostic, no proxy, no
LB. istiod even discovers the app's Service but never touches the Gateway. Put
the Gateway in `openshift-ingress`; the `HTTPRoute` can live with the app and
attach across namespaces.

### 4. agentgateway's proxy needs an SCC (the data plane, not the control plane)
The control plane installs fine under `restricted-v2`. The **proxy** pod
hardcodes `runAsUser: 10101`, which `restricted-v2` rejects
(`runAsUser: Invalid value: 10101: must be in the ranges [1000730000, ...]`), so
the proxy ReplicaSet can't create pods (`ReplicaFailure` / `FailedCreate`), no
endpoints, requests get HTTP 000. Fix: grant the gateway's service account
(named after the Gateway) `anyuid` (or a tailored custom SCC), then roll the
proxy. The `net.ipv4.ip_unprivileged_port_start` sysctl it sets is a *safe*
sysctl on k8s 1.34, so that is not the blocker, only the UID.

### 5. Cross-zone load balancing (clean external testing)
The cluster has 2 workers (2 AZs) but each gateway's Classic ELB spans 3 AZ
subnets. With cross-zone LB off, the node in the empty AZ blackholes ~1/3 of
connections, which looks exactly like intermittent downtime from a laptop
(`code=000`, instant fail) while the app is perfectly healthy. Annotate the
gateway Services with
`service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled=true`
and all ELB IPs answer. This was the difference between a noisy monitor and a
clean `fail=0`.

### 6. The migration is zero-downtime because both gateways serve at once
agentgateway is brought up *alongside* the OpenShift gateway and the one
`HTTPRoute` is given **two `parentRefs`** (both gateways), so both LBs serve the
app. Only then is DNS swapped. The old gateway stays up through propagation, so
there is no gap, confirmed by the monitor (`evidence/availability-evidence.log`).

## Why no Gateway API CRD work is needed
agentgateway supports Gateway API 1.3-1.5. OpenShift 4.21 provides 1.3.0, inside
that range, so you install agentgateway against the cluster's existing CRDs and
**skip** the upstream `standard-install.yaml` apply entirely. Replacing or
upgrading the OpenShift-managed CRDs is what causes problems (the Ingress
Operator owns them, goes `Degraded` on a conflict, and incompatible CRDs can
block cluster upgrades). If you ever need newer CRDs, OpenShift 4.22 ships
Gateway API 1.4.1 and also lifts the restriction so you can self-manage up to
1.5.

## Below the floor: OpenShift 4.20 / Gateway API 1.2.1
We also tested OCP 4.20.25, which the Ingress Operator pins to Gateway API
`1.2.1`, below agentgateway's documented `1.3` floor. agentgateway still
installed and served end to end: control plane up, Gateway `Programmed`,
HTTPRoute attached, proxy serving `200`s (same `anyuid` SCC step). So for core
`Gateway` + `HTTPRoute`, agentgateway functionally runs on 1.2.1.

Keep it honest: **it works but 1.2.1 is unsupported** (docs floor is 1.3), and we
exercised only the core routing path, anything needing a CRD field/kind newer
than 1.2.1, or `ListenerSet`, is not there. Net: OpenShift is not a hard wall
even on 1.2.1, but the supported guidance is 1.3+ (OCP 4.21 or later). The install
is identical to the steps above, the only difference is the cluster's CRD version.

## Helm: what to install (and the ListenerSet flag)
On OpenShift, the install is exactly three pieces, the same on 1.2.1, 1.3.0 and
1.4.1:
1. **Do NOT** apply the upstream Gateway API CRDs (`standard-install.yaml`). The
   Ingress Operator owns them.
2. `enterprise-agentgateway-crds` chart (agentgateway's own config CRDs).
3. `enterprise-agentgateway` control plane (with `licensing.licenseKey`).
Then grant the gateway's service account `anyuid` so the proxy schedules.

**ListenerSet / `installEnterpriseListenerSetCRD` — verified, and not what the
chart-source suggests.** The agentgateway CRD chart *source* carries an
`installEnterpriseListenerSetCRD` value, but the **released `v2026.6.1` chart does
not ship `EnterpriseListenerSet`**: the value is not recognised (a no-op) and no
such CRD renders or installs. Verified with `helm show values` and
`helm template`. **ListenerSet itself is a different matter, and the feature is NOT missing from
agentgateway.** agentgateway's controller does implement the upstream Gateway
API `ListenerSet` (builder, status reconciliation, GEP-1713 precedence,
conformance tests). The blocker on OpenShift is the CRD's release channel:
upstream `ListenerSet` is experimental-channel in GW API 1.3/1.4 and only reaches
the **standard** channel in **1.5**. OpenShift installs the standard channel and
blocks adding CRDs, so the `ListenerSet` CRD is absent on current OpenShift,
neither 4.21 (1.3.0) nor 4.22 (1.4.1 standard) has it; you'd need an OpenShift
release on GW API 1.5. So:
- **Off OpenShift:** install the ListenerSet CRD (experimental pre-1.5, standard
  from 1.5) and agentgateway honours it.
- **On OpenShift today:** no native ListenerSet (standard channel lacks it until
  1.5), and the `EnterpriseListenerSet` bridge isn't in the released agentgateway
  chart. The working `EnterpriseListenerSet` bridge currently lives in **kgateway**
  enterprise. So for ListenerSet on agentgateway on OpenShift today there is no
  path yet: use kgateway, or wait for agentgateway's EnterpriseListenerSet release
  or an OCP release on GW API 1.5.

## Files
- `scripts/` - 00 install OpenShift, 01 sample app, 02 monitor, 03 install
  agentgateway, 04 migrate+cutover, 99 cleanup.
- `yaml/` - the manifests (backend, GatewayClass, both Gateways, the dual-parent
  HTTPRoute).
- `evidence/availability-evidence.log` - the live monitor output across the
  cutover (`fail=0`).
- `env.sample` - the variables to set.
