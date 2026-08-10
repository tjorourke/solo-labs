# Anthos Service Mesh to Enterprise Istio Ambient, on GKE

Migrate off Google Anthos Service Mesh (ASM, rebranded Cloud Service Mesh, still `asm-managed`
everywhere in the cluster) onto Solo Enterprise Istio in ambient mode, on real GKE, without
touching the ASM control plane. The full write-up with the measurements,
diagrams and the migration checklist is at
[masterthemesh.com/solo/istio-ambient-migration-gke/](https://www.masterthemesh.com/solo/istio-ambient-migration-gke/).

## What it builds

- A new GKE cluster running Solo Enterprise Istio `1.30.3-solo`, installed sidecar-first, with
  Enterprise agentgateway as the ingress.
- A Vault-backed mesh CA (cert-manager + istio-csr) on an RSA-only signing role, so the RSA to EC
  transition ambient forces is rehearsed rather than discovered.
- The `petstore` workload catalogue: an L7 namespace (canary + method authorization), an L4-only
  namespace (Redis + identity authorization), and a legacy namespace that never migrates and holds
  both the sidecar caller and the load generator.
- A second, identical cluster on community Istio, used purely as an A/B control.
- An east-west bridge back to the ASM cluster, built from a plain Istio Gateway, VirtualService,
  ServiceEntry and an internal GCP LoadBalancer.

## Layout

```
yaml/10-apps-sidecar/       the workloads, all starting on sidecars
yaml/20-policies-sidecar/   mesh-wide STRICT, the canary, the L4 and L7 policies
yaml/30-waypoints/          the waypoint Gateway for the L7 namespace
yaml/40-policies-waypoint/  the L7 policy converted from selector to targetRefs
yaml/50-crosscluster/       east-west gateway values, exposing side, calling side
yaml/60-pki/                istio-csr values, the Vault Issuer, the signing-role script
```

The manifests are edition-neutral: the same files run on the Solo distribution and on community
Istio. Only the install commands differ, and those are in the write-up.

## The one thing to get right

The L7 namespace migrates waypoint-first, and the old selector-based `AuthorizationPolicy` is
deleted **before** the namespace is enrolled into ambient, not after. Deleting it last was measured
at `Code 503 : 159 (2.1 %)` across the cutover, a window of total failure that ends only when the
policy goes. Deleting it before enrolment measured `Code 200 : 7500 (100.0 %)` with the denied
method still returning `403` at every gate.

## Requires

- A GCP project with `container.clusters.*` and the ability to create clusters and internal
  LoadBalancers.
- Solo Enterprise Istio and Enterprise agentgateway licence keys.
- `kubectl`, `helm`, `istioctl`, `gcloud`, `jq`, `python3`.
