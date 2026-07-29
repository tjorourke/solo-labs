# Vault + istio-csr: sidecars on RSA, ambient on EC

Sidecars ask the mesh CA for RSA certificates. ztunnel can only ask for
ECDSA P-256 — there is no RSA option in ztunnel. So when the mesh CA is
HashiCorp Vault behind cert-manager istio-csr and the signing role is locked
to `key_type=rsa` (RSA-4096 root, RSA-4096 intermediate, the way an estate
that standardised on RSA years ago actually runs), the sidecar estate works
perfectly for years — and the very first ambient enrolment is rejected on
the spot:

```
role requires keys of type rsa
```

The lab proves the safe way through, live:

1. **RSA baseline** — Istio in sidecar mode, istiod's built-in CA off,
   `caAddress` pointed at istio-csr, everything signed by Vault. Two app
   namespaces under STRICT mTLS: `ledger` (never migrates) and `payments`
   (will migrate), clients calling across the boundary every 2s.
2. **Ambient control plane arrives under load** — istio-csr gains
   `caTrustedNodeAccounts` (the ambient impersonation model), istiod flips to
   `profile=ambient`, CNI + ztunnel install. fortio runs across the whole
   change and scores 100%; the ledger workload keeps the exact same
   certificate serial (nothing re-issued, nothing restarted).
   Then one rolling restart of the sidecar namespace. A sidecar's config is
   stamped in at injection time: istiod's ambient profile injects new pods
   with `ISTIO_META_ENABLE_HBONE=true` (the "this proxy can accept HBONE"
   flag), but pods created before the profile change still run the old
   template without it, so ztunnel could only reach them in plaintext, which
   STRICT rejects. The roll re-injects them with the current template; they
   accept HBONE mTLS from ambient callers, and their fresh certs are still
   RSA, proving the rsa-only role keeps serving sidecars after ambient
   arrives. Do this roll before any namespace they talk to migrates.
3. **The rejection, somewhere safe** — a scratch `preflight` namespace is the
   first thing enrolled into ambient. ztunnel's EC CSR is refused by the
   RSA-only role; the preserved CertificateRequest carries the exact Vault
   error. This is the dev rehearsal that saves the production estate.
4. **The fix is `key_type=any`, not `ec`** — key type is chosen by the
   client: sidecars keep sending RSA, ztunnel sends EC, and the role just has
   to permit both. Flip to `any`: preflight gets its EC cert, ledger's RSA
   cert is untouched (same serial).
5. **Migrate `payments`** — namespace label flip + rolling restart, fortio
   scoring 100% across it. Afterwards: EC certs in ztunnel for payments, RSA
   in Envoy for ledger, and sidecar-to-ambient mTLS working in both
   directions.
6. **The sidecar outage** — set the role to `key_type=ec` and the very next
   sidecar issuance in ledger fails (`role requires keys of type ec`): new
   pods stick at not-ready immediately, and every existing sidecar follows
   within one cert TTL when its renewal bounces. That is why the migration
   posture is `any`: it is the only setting that serves a mixed RSA/EC
   estate.

Everything in this lab is upstream OSS: Istio images from `docker.io/istio`,
upstream Helm charts, upstream cert-manager, istio-csr and Vault. No licence,
no registry auth, no enterprise CRDs.

## Run it

The demo is ten numbered scripts, run in order. Every script prints each
command before it runs it, so an audience sees exactly what is happening,
and each one ends by pointing at the next.

```bash
./scripts/01-setup.sh            # the RSA world
./scripts/02-deploy-apps.sh      # two namespaces, STRICT mTLS, live traffic
./scripts/03-show-certs.sh       # RSA everywhere, issued by Vault
./scripts/04-enable-ambient.sh   # ambient arrives; nothing enrolled
./scripts/05-interop-roll.sh     # one roll so sidecars accept HBONE
./scripts/06-preflight-break.sh  # first enrolment -> Vault says no (on purpose)
./scripts/07-vault-allow-ec.sh   # the fix: role -> key_type=any
./scripts/08-migrate-payments.sh # the real migration, under fortio load
./scripts/03-show-certs.sh       # the final inventory: RSA + EC, one issuer
./scripts/09-sidecar-outage.sh   # why the role must stay 'any'
./scripts/99-teardown.sh

# or the whole arc, automated with assertions:
./scripts/e2e.sh
```

## What each script does

- **`01-setup.sh`** — builds the starting world: kind cluster, cert-manager,
  Vault (dev mode), the all-RSA PKI (root, intermediate, signing role locked
  to `key_type=rsa`), the cert-manager Vault Issuer (Kubernetes auth, no
  stored token), istio-csr, and Istio in sidecar mode with its built-in CA
  disabled (`ENABLE_CA_SERVER=false`) and `caAddress` pointed at istio-csr.
  From here Vault is the only signer in the cluster.
- **`02-deploy-apps.sh`** — deploys `ledger` and `payments` (both sidecar),
  clients curling across namespaces every 2s, fortio, and mesh-wide STRICT
  mTLS. The pods going Ready is itself the proof the Vault CA path works.
- **`03-show-certs.sh`** — the certificate inventory, read from the live
  serving state (Envoy SDS for sidecars, ztunnel for ambient): data plane,
  key algorithm, serial and issuer per workload. Run it at any point; run it
  at the end for the finale table.
- **`04-enable-ambient.sh`** — the ambient control plane arrives: istio-csr
  gains `caTrustedNodeAccounts=istio-system/ztunnel` (the ambient
  impersonation model, istio-csr ≥ v0.12.0), istiod flips to
  `profile=ambient`, CNI and ztunnel install with the same `caAddress`.
  Nothing is enrolled, ztunnel sends zero CSRs, no app restarts.
- **`05-interop-roll.sh`** — one rolling restart of the sidecar namespace.
  Sidecars injected before the ambient profile lack
  `ISTIO_META_ENABLE_HBONE`, so ztunnel could only reach them in plaintext,
  which STRICT rejects. Shows the HBONE flag on the new pods, istiod's
  PROTOCOL=HBONE advertisement, and that the fresh certs are still RSA.
- **`06-preflight-break.sh`** — the step that is supposed to fail. Enrols
  the scratch `preflight` namespace into ambient; ztunnel's EC CSR is
  rejected by the rsa-only role, and the script shows the preserved
  CertificateRequest carrying Vault's exact error and ztunnel's own log.
- **`07-vault-allow-ec.sh`** — the fix: rewrites the role with
  `key_type=any`, waits for ztunnel's retry to collect preflight's EC cert,
  and proves ledger's RSA cert is untouched (same serial).
- **`08-migrate-payments.sh`** — the real migration, with fortio running:
  namespace label flip, rolling restart, scoreboard, then the after-state
  (no sidecars, EC certs in ztunnel, live 200s in both directions across the
  two data planes).
- **`09-sidecar-outage.sh`** — what `key_type=ec` would do: a new ledger
  replica's RSA CSR bounces and the pod sticks at not-ready, and every
  existing sidecar is one cert renewal away from the same fate. Repairs with
  `any` and shows the stuck pod heal itself.
- **`99-teardown.sh`** — deletes the kind cluster.
- **`vault-pki.sh`** — the PKI engine the others call: `bootstrap`,
  `role rsa|any|ec`, `show`, all via `kubectl exec` into the Vault pod (no
  local vault CLI needed).
- **`e2e.sh`** — the whole arc as one automated run with assertions; exits
  non-zero if any step's proof fails. This is what validates the lab.

## What's in yaml/

| Path | What it is |
|---|---|
| `yaml/00-pki/` | the cert-manager Vault Issuer + the token RBAC |
| `yaml/10-apps/` | ledger + payments + STRICT mTLS |
| `yaml/20-preflight/` | the scratch namespace that takes the hit |

Versions: Istio 1.30.3 (upstream), cert-manager v1.21.1, istio-csr v0.16.0
(ambient support needs ≥ v0.12.0), Vault chart 0.34.0.

Vault runs in dev mode (in-memory, HTTP, root token `root`) — right for a
lab, never for production. The Issuer authenticates with a short-lived
audience-scoped ServiceAccount token; no Vault token is stored in the cluster.

## InfoSec notes

Three things a security change request should cover (the lab page has the
full write-up):

1. `key_type=any` relaxes CA-side key-policy enforcement for the migration
   window. Bounded: only istio-csr reaches this role, and the only CSR
   generators behind it are istio-agent (RSA-2048) and ztunnel (P-256). End
   state after the last sidecar: `key_type=ec key_bits=256`, stricter than
   today.
2. ECDSA P-256 enters scope: a strength upgrade over RSA-2048 (~128-bit vs
   ~112-bit), approved in FIPS 186-5 and NCSC guidance. Roots/HSMs untouched.
3. `caTrustedNodeAccounts` lets the ztunnel SA request certs for workloads on
   its node: a real trust-model change to accept explicitly, though it stays
   within the node blast radius a cluster already carries.

Unchanged: trust anchors, TTLs, SPIFFE naming, SAN policy, STRICT mTLS, and
the Vault audit trail (preserved CertificateRequests arguably improve it).

## References

- [Vault PKI secrets engine API](https://developer.hashicorp.com/vault/api-docs/secret/pki) —
  the role's `key_type` accepts `rsa`, `ec`, `ed25519` and `any`, and
  `key_bits` is "ignored ... in signing operations when `key_type=any`".
  `any` applies to the `sign` endpoints (client-generated keys, which is all
  istio-csr and cert-manager ever use); it cannot be used where Vault
  generates the key itself (`issue`, root/intermediate generation).
- [cert-manager istio-csr](https://cert-manager.io/docs/usage/istio-csr/) —
  ambient support (trusted CA node accounts) needs istio-csr ≥ v0.12.0.

