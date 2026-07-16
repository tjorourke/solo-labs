# Ambient port audit: which ports are open, which are used, which should go

A monolith gets split into microservices and every service drags its old port
surface with it: the admin port nobody calls any more, the debug port that was
handy in staging, the legacy port a retired client used. The mesh encrypts all
of it and the AuthorizationPolicy allows most of it, but nobody can say which
ports are actually earning their place.

This lab builds the audit that answers it, on Solo Istio in ambient mode, with
nothing beyond what ztunnel already emits:

- **svc-a → svc-b over ztunnel**, mTLS via HBONE, no sidecars.
- svc-b exposes **eleven ports**; svc-a uses **six** (8080-8082, 9090-9092);
  the AuthorizationPolicy allows **ten**, so four allowed ports never see a
  byte; port 7070 is exposed but not allowed, so a probe to it is denied by
  ztunnel and logged.
- **ztunnel access logs switched to JSON** (`LOG_FORMAT=json`) so they parse
  with jq instead of regex.
- A **collector DaemonSet**: one pod per node tails its LOCAL ztunnel's access
  logs (each ztunnel only sees its own node's pods) and merge-patches its OWN
  key in one central ConfigMap. Merge patches on distinct keys are
  conflict-free, so many nodes write the same ConfigMap concurrently with no
  resourceVersion/409 retry dance.
- An **aggregator CronJob**: merges the node keys, reads the configured
  surface (Service ports + AuthorizationPolicy ports) and writes `report.json`
  with, per service: `configured_service_ports`, `authz_allowed_ports`,
  `used_ports`, `unused_ports`, `authz_allowed_never_used`, `denied_attempts`.

The end state is a machine-readable answer to three questions, per service and
per pod, over time: what is open, what is used, and what should be closed.

## Why Enterprise

The mesh is installed and lifecycle-managed by the Gloo Operator: one
`ServiceMeshController` CR renders istiod, istio-cni and ztunnel from the Solo
Istio images, with upgrades by editing `.spec.version`. The audit pattern
itself is plain Kubernetes + ztunnel behaviour.

## Watch the trust domain

The Gloo Operator sets the mesh `trustDomain` to the ServiceMeshController's
`.spec.cluster` (here `port-audit`), so identities are
`spiffe://port-audit/ns/...` and the policy principal is
`port-audit/ns/port-audit/sa/svc-a`. Write it as `cluster.local/...` and it
matches nothing, which turns the ALLOW policy into a deny-all for svc-b. The
ztunnel access log's `src.identity` field is the quickest way to see the real
trust domain.

## Run it

```bash
export SECRETS_FILE=~/path/to/secrets.sh   # exports SOLO_ISTIO_LICENSE_KEY
./scripts/setup-cluster.sh                 # kind + operator + ambient mesh + JSON logs

kubectl --context kind-port-audit apply -f yaml/10-app/
kubectl --context kind-port-audit apply -f yaml/20-policy/
kubectl --context kind-port-audit apply -f yaml/30-audit/

# after ~90s (collectors patch every 30s, aggregator runs every 60s):
kubectl --context kind-port-audit -n port-audit-system get cm port-audit-report \
  -o jsonpath='{.data.report\.json}' | jq .
```

Or the whole thing, standup to assertions, in one go:

```bash
SECRETS_FILE=~/path/to/secrets.sh ./scripts/e2e.sh
```

## The port story on svc-b

| Port | In the Service | In the policy | svc-a calls it | Report verdict |
| ---- | -------------- | ------------- | -------------- | -------------- |
| 8080 http-api | yes | yes | yes | used |
| 8081 inventory | yes | yes | yes | used |
| 8082 orders | yes | yes | yes | used |
| 9090 metrics | yes | yes | yes | used |
| 9091 health | yes | yes | yes | used |
| 9092 events | yes | yes | yes | used |
| 8083 admin | yes | yes | no | `authz_allowed_never_used` |
| 8084 debug | yes | yes | no | `authz_allowed_never_used` |
| 9093 profiling | yes | yes | no | `authz_allowed_never_used` |
| 9094 legacy-sync | yes | yes | no | `authz_allowed_never_used` |
| 7070 legacy | yes | no | probed once | `denied_attempts` |

`scripts/e2e.sh` runs the traffic for a five-minute soak (override with
`SOAK=seconds`) before it judges the report, so "used" means used during a
real observation window, not a single lucky request.

## Layout

```
kind/cluster.yaml            1 control-plane + 2 workers (per-node story needs 2)
scripts/setup-cluster.sh     kind + Gloo Operator + SMC(Ambient) + LOG_FORMAT=json
scripts/e2e.sh               full run + report assertions
yaml/00-mesh/                ServiceMeshController
yaml/10-app/                 svc-a (client), svc-b (five listeners, spread across workers)
yaml/20-policy/              the L4 AuthorizationPolicy (over-provisioned on purpose)
yaml/30-audit/               report ConfigMap, RBAC, collector DaemonSet, aggregator CronJob
```

## Teardown

```bash
kind delete cluster --name port-audit
```
