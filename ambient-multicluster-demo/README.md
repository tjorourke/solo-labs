# istio-ambient-demo-kind

**Three-part customer demo for Solo Enterprise for Istio (ambient), driven from `demo.ipynb`.** A mash-up of `agentgw-multi-cluster-kind` (the multicluster story, per the "Solo Enterprise for Istio" deck from slide 24) and `istio-ambient-cert-identity-kind` (the L4/L7 workload-identity story), with **one** setup script, inline architecture and state diagrams, and no per-part helm plumbing in the demo itself.

- **Part 1 — Multicluster.** Bookinfo on both clusters, east-west gateways + `istioctl multicluster link`, agentgateway ingress, global services (`solo.io/service-scope=global` → `*.mesh.internal`), cross-cluster failover, takeover of the local hostname (`solo.io/service-takeover=true`), then the same ingress doing canary + rate limit.
- **Part 2 — L4 identity.** The petshop on `mesh1`: the certificate is the identity, authorise on it in ztunnel, identity-aware access logs, the shared-ServiceAccount gap, workload claims closing it — all at L4, no proxy in the path.
- **Part 3 — Waypoint (L7).** Add the agentgateway waypoint to the petshop: JWT authorisation, canary routing and identity-keyed rate limiting. Needs the petshop from Part 2 §2.1.

The parts run **independently** — pick one per customer, or run all three. This lab is a personal demo driver: no `index.html`, not on the site.

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
./demo-scripts/reset.sh       # wipe ALL demo workloads (both parts) back to square 1, keep the platform
./demo-scripts/wake.sh        # after a laptop sleep (expired 24h leaf certs)
./setup.sh teardown           # delete both clusters (full rebuild)
```

**Three levels of reset**, lightest to heaviest:
- **`1.R` / `2.R` / `3.R`** (notebook cells) — per-part *soft* reset; undoes that part's steps but keeps the app deployed, for a quick re-run of the same part.
- **`./demo-scripts/reset.sh`** — hard reset the whole demo to square 1: removes every demo workload from both parts (bookinfo, petshop, warehouse) and reverts ztunnel to claims-off, but leaves the platform (mesh, peering, agentgateway, Gloo UI, Keycloak) up. No rebuild — restart the demo from §1.1 / §2.1. Use this between demo runs, or to start Phase 2 clean.
- **`./setup.sh teardown`** — delete the clusters entirely (full ~20-min rebuild).

## What setup.sh stands up

kind ×2 → MetalLB (pools `.140-.150` / `.160-.170` inside the kind net) → shared root CA + per-cluster intermediates (`cacerts`) → Gateway API CRDs → Solo Istio ambient via plain Helm (licence, per-cluster trust domain, multicluster peering values, JSON ztunnel logs — all Helm values, no patches) → `istioctl multicluster expose` + `link` → Gloo UI (mgmt plane on mesh1, agent on both) → Solo Enterprise agentgateway on both clusters → Keycloak (realm `petshop`, alice/user + bob/admin) on mesh1.

Each notebook part has a reset cell (`1.R` / `2.R` / `3.R`) so it can be re-run without a rebuild.
