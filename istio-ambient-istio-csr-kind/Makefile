# Vault + istio-csr sidecar-to-ambient lab. Everything is upstream OSS —
# no licence, no registry auth. Needs docker, kind, kubectl, helm, jq,
# istioctl, openssl.
#
#   make setup       # kind + Vault RSA PKI + istio-csr + Istio (sidecar)
#   make deploy      # ledger + payments (both sidecar) + STRICT mTLS
#   make certs       # inventory: dataplane + key algorithm per workload
#   make fortio      # bounded 10s load: the zero-downtime scoreboard
#   make ambient     # ambient control plane arrives; nothing enrolled
#   make interop     # roll the sidecar ns ONCE: re-inject with HBONE (still RSA)
#   make preflight   # enrol the scratch ns: watch Vault reject ztunnel's EC CSR
#   make rejections  # the preserved CertificateRequests + ztunnel logs
#   make unlock      # Vault role -> key_type=any (RSA still fine, EC now allowed)
#   make migrate     # payments -> ambient (label flip + rolling restart)
#   make ec-trap     # role -> ec only: the next sidecar issuance breaks (then: make unlock)
#   make e2e         # the whole arc, asserted
#   make clean       # delete the kind cluster
CTX ?= kind-istio-csr

.PHONY: setup deploy certs fortio ambient interop preflight rejections unlock migrate ec-trap e2e clean

setup:
	./scripts/setup-cluster.sh

deploy:
	kubectl --context $(CTX) apply -f yaml/10-apps/
	kubectl --context $(CTX) -n ledger rollout status deploy/httpbin deploy/client deploy/fortio --timeout=180s
	kubectl --context $(CTX) -n payments rollout status deploy/httpbin deploy/client --timeout=180s

certs:
	./scripts/certs.sh

fortio:
	kubectl --context $(CTX) -n ledger exec deploy/fortio -c fortio -- \
	  fortio load -c 4 -qps 25 -t 10s -quiet http://httpbin.payments:8000/status/200 | grep "Code "

ambient:
	./scripts/ambient-enable.sh

# Sidecars injected before the ambient profile lack ISTIO_META_ENABLE_HBONE,
# so ztunnel can only reach them in plaintext (STRICT rejects it). Roll them
# once, BEFORE any namespace they talk to migrates; they come back HBONE-capable
# and still RSA.
interop:
	kubectl --context $(CTX) -n ledger rollout restart deploy/httpbin deploy/client deploy/fortio
	kubectl --context $(CTX) -n ledger rollout status deploy/httpbin deploy/client deploy/fortio --timeout=180s

preflight:
	kubectl --context $(CTX) apply -f yaml/20-preflight/preflight.yaml
	kubectl --context $(CTX) -n preflight rollout status deploy/httpbin --timeout=120s

rejections:
	kubectl --context $(CTX) -n istio-system get certificaterequests.cert-manager.io \
	  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MESSAGE:.status.conditions[?(@.type=="Ready")].message' | tail -20
	kubectl --context $(CTX) -n istio-system logs ds/ztunnel --tail=20 | grep -i -E 'error|warn' || true

unlock:
	./scripts/vault-pki.sh role any

migrate:
	kubectl --context $(CTX) label ns payments istio.io/dataplane-mode=ambient istio-injection- --overwrite
	kubectl --context $(CTX) -n payments rollout restart deploy/httpbin deploy/client
	kubectl --context $(CTX) -n payments rollout status deploy/httpbin deploy/client --timeout=180s

ec-trap:
	./scripts/vault-pki.sh role ec
	kubectl --context $(CTX) -n ledger scale deploy/httpbin --replicas=2
	@echo "watch the new replica fail to get a cert: make rejections — then repair with: make unlock"

e2e:
	./scripts/e2e.sh

clean:
	kind delete cluster --name istio-csr
