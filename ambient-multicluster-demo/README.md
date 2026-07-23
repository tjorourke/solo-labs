# istio-ambient-demo-kind

**Two-part customer demo for Solo Enterprise for Istio (ambient), driven from `demo.ipynb`.** A mash-up of `agentgw-multi-cluster-kind` (the multicluster story, per the "Solo Enterprise for Istio" deck from slide 24) and `istio-ambient-cert-identity-kind` (the L4/L7 workload-identity story) — with **one** setup script and no per-part helm plumbing in the demo itself.

- **Part 1 — Multicluster.** Bookinfo on both clusters, east-west gateways + `istioctl multicluster link`, agentgateway ingress, global services (`solo.io/service-scope=global` → `*.mesh.internal`), cross-cluster failover, takeover of the local hostname (`solo.io/service-takeover=true`), then the same ingress doing canary + rate limit, and an agentgateway waypoint.
- **Part 2 — Workload identity.** The petshop on `mesh1`: SVID = identity, L4 authorization in ztunnel, identity-aware access logs, the shared-ServiceAccount gap, workload claims closing it (still L4), then the agentgateway waypoint for JWT + CEL + canary + identity-keyed rate limiting.

The parts run **independently** — pick one per customer, or run both. This lab is a personal demo driver: no `index.html`, not on the site.

## Stack (validated live)

| Piece | Version |
|---|---|
| Solo Istio (Helm charts + images, ambient) | `1.30.3-solo` |
| Solo Enterprise for agentgateway (ingress + waypoint) | `v2026.7.0` |
| Gloo Platform (Gloo UI, mgmt on mesh1 + agents on both) | `2.13.2` |
| Gateway API | `v1.5.1` |
| kind clusters | `mesh1` + `mesh2` (unique — no clash with other labs) |

Trust domains are per-cluster (`mesh1` / `mesh2`), the documented 1.30.x multicluster flow — Part 2's principals read `mesh1/ns/petshop/sa/<sa>`.

## Run it

```bash
# licences: SOLO_ISTIO_LICENSE_KEY + AGENTGATEWAY_LICENSE_KEY
SECRETS_FILE=~/code/solo/secrets/secrets-envs.sh ./setup.sh   # ~15-20 min first run

./demo-scripts/consoles.sh    # Gloo UI (service graph spans both clusters)
# open demo.ipynb (Bash kernel) → run the Connect cell → Part 1 and/or Part 2
```

Day-2:

```bash
./demo-scripts/wake.sh        # after a laptop sleep (expired 24h leaf certs)
./setup.sh teardown           # delete both clusters
```

## What setup.sh stands up

kind ×2 → MetalLB (pools `.140-.150` / `.160-.170` inside the kind net) → shared root CA + per-cluster intermediates (`cacerts`) → Gateway API CRDs → Solo Istio ambient via plain Helm (licence, per-cluster trust domain, multicluster peering values, JSON ztunnel logs — all Helm values, no patches) → `istioctl multicluster expose` + `link` → Gloo UI (mgmt plane on mesh1, agent on both) → Solo Enterprise agentgateway on both clusters → Keycloak (realm `petshop`, alice/user + bob/admin) on mesh1.

Each notebook part has a reset cell (`1.R` / `2.R`) so it can be re-run without a rebuild.
