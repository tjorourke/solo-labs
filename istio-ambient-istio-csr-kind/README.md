# Vault + istio-csr: sidecars on RSA, ambient on EC

A kind lab for the estate that standardised on RSA years ago and now wants
ambient. The mesh CA is HashiCorp Vault behind cert-manager istio-csr, and the
whole PKI starts as RSA: RSA-4096 root, RSA-4096 intermediate, and a Vault
signing role locked to `key_type=rsa`. Sidecars are happy — istio-agent
generates RSA-2048 workload keys by default.

Then ambient arrives. ztunnel generates ECDSA P-256 keys for its workload
CSRs, and that is the only key type it can generate — there is no RSA option
in ztunnel. So the RSA-only Vault role rejects every ztunnel CSR:

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
   Then one rolling restart of the sidecar namespace: sidecars injected
   before the ambient profile lack `ISTIO_META_ENABLE_HBONE`, so ztunnel
   could only reach them in plaintext, which STRICT rejects. Re-injected
   sidecars accept HBONE mTLS from ambient callers — and their fresh certs
   are still RSA, proving the rsa-only role keeps serving sidecars after
   ambient arrives. Do this roll before any namespace they talk to migrates.
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
6. **The ec-only trap** — set the role to `key_type=ec` and the very next
   sidecar issuance in ledger fails (`role requires keys of type ec`). That
   is why the migration posture is `any`: it is the only setting that serves
   a mixed RSA/EC estate.

Everything in this lab is upstream OSS: Istio images from `docker.io/istio`,
upstream Helm charts, upstream cert-manager, istio-csr and Vault. No licence,
no registry auth, no enterprise CRDs.

## Run it

```bash
make setup
make deploy && make certs

# the guided beats
make fortio          # scoreboard before anything changes
make ambient         # ambient control plane arrives (nothing enrolled)
make interop         # roll the sidecar ns once: HBONE-capable, still RSA
make preflight       # first enrolment -> watch Vault say no
make rejections      # the preserved CertificateRequests + ztunnel errors
make unlock          # Vault role -> key_type=any
make migrate         # payments -> ambient
make certs           # RSA in ledger, EC in payments
make ec-trap         # why 'any' and never 'ec' (repair: make unlock)

# or the whole arc, asserted
make e2e
make clean
```

## What's in here

| Path | What it is |
|---|---|
| `scripts/setup-cluster.sh` | kind + cert-manager + Vault (dev mode, RSA PKI) + Vault Issuer + istio-csr + Istio sidecar mode |
| `scripts/vault-pki.sh` | the PKI: `bootstrap`, `role rsa\|any\|ec`, `show` — all via `kubectl exec`, no local vault CLI |
| `scripts/ambient-enable.sh` | istio-csr `caTrustedNodeAccounts`, istiod `profile=ambient`, CNI, ztunnel |
| `scripts/certs.sh` | live cert inventory: dataplane + key algorithm + serial per workload, read from Envoy/ztunnel |
| `scripts/e2e.sh` | the whole arc with assertions |
| `yaml/00-pki/` | the cert-manager Vault Issuer + the token RBAC |
| `yaml/10-apps/` | ledger + payments + STRICT mTLS |
| `yaml/20-preflight/` | the scratch namespace that takes the hit |

Versions: Istio 1.30.3 (upstream), cert-manager v1.21.1, istio-csr v0.16.0
(ambient support needs ≥ v0.12.0), Vault chart 0.34.0.

Vault runs in dev mode (in-memory, HTTP, root token `root`) — right for a
lab, never for production. The Issuer authenticates with a short-lived
audience-scoped ServiceAccount token; no Vault token is stored in the cluster.

## References

- [Vault PKI secrets engine API](https://developer.hashicorp.com/vault/api-docs/secret/pki) —
  the role's `key_type` accepts `rsa`, `ec`, `ed25519` and `any`, and
  `key_bits` is "ignored ... in signing operations when `key_type=any`".
  `any` applies to the `sign` endpoints (client-generated keys, which is all
  istio-csr and cert-manager ever use); it cannot be used where Vault
  generates the key itself (`issue`, root/intermediate generation).
- [cert-manager istio-csr](https://cert-manager.io/docs/usage/istio-csr/) —
  ambient support (trusted CA node accounts) needs istio-csr ≥ v0.12.0.

