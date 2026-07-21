# istio-ambient-cert-identity-kind

**The service's identity is its certificate. Authorize on it at L4, add a waypoint for L7, and hook an IdP in for JWT — all on one petshop app.**

An ambient-only kind lab (Solo Enterprise for Istio, ambient mode) that walks a petshop app through the whole ambient security model: SPIFFE identity, L4 authorization in ztunnel, identity-aware access logs, an opt-in waypoint, a Keycloak IdP, claim-based L7 JWT authorization, and the Solo Enterprise differences — ending on an in-place upgrade to the 1.30 line, where **workload claims** close the shared-ServiceAccount gap live.

- **Edition:** Enterprise (Solo Istio Helm charts + Solo images).
- **Validated live on:** Solo Istio `1.29.3-solo`, upgraded in place to `1.30.3-solo` for the workload-claims step; Gateway API `v1.5.1`.

**Two ways to run it:**
- **`demo.ipynb`** — the guided walkthrough. Every command and manifest is shown in the cell; nothing hidden behind a script.
- **This README + `make`** — the quick path.

## The cast (namespace `petshop`, ambient)

| Workload | ServiceAccount → identity | Role |
|---|---|---|
| `petstore` | `sa/petstore` | the API — `GET /pets`, `DELETE /pets/{id}` |
| `storefront` | `sa/storefront` | client the L4 policy **allows** |
| `analytics` | `sa/analytics` | client the L4 policy **denies** |
| `checkout-blue` | `sa/checkout` | shares one SA with green … |
| `checkout-green` | `sa/checkout` | … so both present the **same** SVID |

Trust domain is the cluster name, so identities are `spiffe://cert-identity/ns/petshop/sa/<sa>` (**not** `cluster.local`). Keycloak runs in its own non-ambient `keycloak` namespace with users `alice` (role `user`) and `bob` (role `admin`).

## Prerequisites

`docker`, `kind`, `kubectl`, `helm`, `istioctl`, `jq`, an **authenticated `gcloud`** (Solo images pull from `us-docker.pkg.dev`), and `SOLO_ISTIO_LICENSE_KEY` (or `SECRETS_FILE`). For the optional Solo UI, also `GLOO_PLATFORM_LICENSE_KEY` (falls back to `SOLO_ISTIO_LICENSE_KEY`).

## Quick run

```bash
make setup SECRETS_FILE=~/code/solo/secrets/secrets-envs.sh   # kind + Solo ambient via Helm + JSON logs
make gloo-ui                                                  # (optional) Solo/Gloo UI mgmt plane + bg port-forward (free local port)
make deploy                                                   # petshop (watch it appear in the UI)

# ── L4: identity ──────────────────────────────────────────────
make svid                # each workload's SVID; checkout-blue/green share ONE cert
make allow-storefront    # storefront 200 ; analytics/checkout denied, by identity
make logs                # ztunnel access logs: src.identity + ALLOW/DENY   (Ctrl-C to stop)
make allow-checkout      # add sa/checkout -> BOTH checkout pods 200 (the gap)
make l4-surface          # 2nd-namespace caller + when(source.namespace) ALLOW + DENY precedence

# ── L7: JWT at a waypoint ─────────────────────────────────────
make waypoint            # opt-in L7 waypoint for the petshop namespace (resets the L4 policies)
make idp                 # Keycloak IdP
make jwt                 # RequestAuthentication + claim-based AuthorizationPolicy
make jwt-test            # no-token 403 / alice GET 200 / alice DELETE 403 / bob DELETE 200

# ── Close the gap: workload claims (1.30 line) ────────────────
make claims-upgrade      # in-place upgrade to 1.30.3-solo + ENABLE_WORKLOAD_CLAIMS (per-pod certs)
make claims              # annotate blue=gold green=silver + CEL claim policy: blue 200, green denied

make clean               # delete the kind cluster
```

## What it proves

1. **Identity = certificate.** `svid` shows one SVID per workload; the shared `sa/checkout` cert is the gap.
2. **Authorize on identity at L4.** ztunnel fails closed: name `storefront` and everything else is denied, no app or waypoint change. `src.identity` in the access log is the evidence.
3. **The SA-scoped ceiling.** `allow-checkout` lets both checkout pods in; you cannot separate them at L4.
3b. **The full L4 match surface.** `l4-surface` shows ztunnel deciding on source **namespace** via a CEL `when` clause (cross-namespace `warehouse-svc` denied) and **DENY beating ALLOW** (analytics blocked even under the namespace ALLOW) — all at L4, no waypoint.
4. **L7 needs a waypoint.** A request JWT is HTTP, so it is validated (`RequestAuthentication`) and authorized (`AuthorizationPolicy` with `request.auth.claims[realm_access][roles]`) at the waypoint — `GET` for any valid token, `DELETE` for admins only.
5. **Solo Enterprise extras.** ztunnel emits L7 telemetry (`method`/`path`/`response_code`) with **no waypoint** — see `istioctl ztunnel-config all <ztunnel> -o json | jq .config.l7Config`.
6. **Workload claims close the gap.** After the in-place 1.30 upgrade, each POD gets its own cert with signed claims; a CEL `when` over `source.claims[...]` separates `checkout-blue` from `checkout-green` at L4.

## Closing the gap — workload claims (upgrade to the 1.30 line)

`make claims-upgrade` rolls the mesh in place to `1.30.3-solo` with `ENABLE_WORKLOAD_CLAIMS=true` on ztunnel (per-POD certs; on the 1.30 line the `-solo` suffix stays on the **image tag** too — the plain `1.30.3` tag is the upstream build with none of the Solo additions). `make claims` then annotates the pods (`solo.io.security-claims/tier: gold | silver` — istiod embeds the claim in each pod's mTLS cert at issuance) and applies `yaml/60-claims/10-allow-gold-checkout.yaml`, a CEL `when` over `source.claims[...]`. Result: `checkout-blue` 200, `checkout-green` denied, even though they share `sa/checkout` — still at L4, still no waypoint. (Distinct from the §9 JWT CEL, which is over the user's request token at the waypoint.) `demo.ipynb` §13 also opens the cert with openssl to show the signed `tier: gold` claim riding next to the SPIFFE URI SAN.

## Notes

- **Trust domain is set to `cert-identity` via `meshConfig.trustDomain`** (a Helm value), not `cluster.local`. A `cluster.local/...` principal matches nothing; because an ALLOW policy then selects the workload, it would deny everything — read `src.identity` in the access log if a policy behaves that way.
- **Dry-run / AUDIT are effectively no-ops at L4** on this line — use real ALLOW/DENY and read the access logs.
- All service-to-service traffic is in-cluster over ztunnel/waypoint; there is no ingress.
