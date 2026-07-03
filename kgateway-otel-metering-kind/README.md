# kgateway → OpenMeter usage metering (kind, OSS)

Meter every API request that passes through **OSS kgateway** and turn it into
per-customer usage in **self-hosted OpenMeter**, using kgateway's **native
OpenTelemetry access-log sink**. No sidecars, no log scraping, no scripts on the
data path. The metering is one `ListenerPolicy`.

```
request ─▶ kgateway (OSS) ─▶ echo
                │  ListenerPolicy: openTelemetry access-log sink (OTLP/gRPC)
                ▼
        OpenMeter collector  (benthos-collector: otel_log input → openmeter output)
                │  CloudEvents  → /api/v1/events
                ▼
        OpenMeter (self-hosted)  ─▶ api_requests_total, grouped by subject/method/route
```

The billed identity (`subject`) is taken from the `x-customer-id` request header.
Because metering reads the access log, it is **off the request path**: if the
collector or OpenMeter is down, live traffic is unaffected.

## Prerequisites

`docker`, `kind`, `kubectl`, `helm`, `jq`. A single small kind node is enough.

## Run it

```bash
scripts/00-openmeter.sh    # self-hosted OpenMeter via docker compose (localhost:48888)
scripts/01-cluster.sh      # fresh single-node kind cluster + Gateway API CRDs
scripts/02-kgateway.sh     # OSS kgateway (helm)
scripts/03-app.sh          # echo backend + Gateway + HTTPRoute
scripts/04-collector.sh    # OpenMeter collector (helm) + Service + ReferenceGrant + ListenerPolicy
scripts/demo.sh 5          # send traffic as two tenants, print per-customer usage
```

Tear down with `scripts/cleanup.sh`.

## Each install and configuration, explained

### 0. Self-hosted OpenMeter (vendor-neutral)

OpenMeter Cloud is now Kong Konnect, so this lab uses the **open-source,
self-hosted** OpenMeter (Apache-2.0) via its docker-compose quickstart. It ships a
preconfigured meter `api_requests_total` (`eventType: request`, `COUNT`, grouped by
`method`/`route`) — which is exactly what this pipeline emits. API on `:48888`.

### 1. kind cluster + Gateway API

A single-node kind cluster, then the upstream Gateway API standard CRDs:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

### 2. OSS kgateway (no license)

```bash
helm upgrade -i kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
  --version v2.2.0 -n kgateway-system --create-namespace --wait
helm upgrade -i kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
  --version v2.2.0 -n kgateway-system --wait
```

This registers the `kgateway` GatewayClass and the controller.

### 3. Backend, Gateway, Route

`yaml/01-echo.yaml` is a tiny echo app. `yaml/02-gateway.yaml` is a `Gateway`
(`gatewayClassName: kgateway`, which auto-provisions the Envoy proxy Deployment/Service
named `http`) plus an `HTTPRoute` to echo.

### 4. OpenMeter collector + the metering policy

Install the OpenMeter collector (Redpanda Connect / benthos build with the custom
`otel_log` input and `openmeter` output):

```bash
helm upgrade -i opentelemetry-collector \
  oci://ghcr.io/openmeterio/helm-charts/benthos-collector --version 1.0.0-beta.229 \
  -n telemetry --create-namespace -f yaml/collector-values.yaml --wait
```

`yaml/collector-values.yaml` sets the pipeline: `otel_log` on `:4317` → a bloblang
mapping that builds a CloudEvent (`type: request`, `subject`, `data.method/route/status`)
→ the `openmeter` output pointed at `http://host.docker.internal:48888`.

Then two pieces of wiring and the policy (`yaml/04-collector-service.yaml`,
`yaml/03-listenerpolicy.yaml`):

- **`Service` on 4317** — the chart's default Service `targetPort` doesn't map to the
  `otel_log` port, so we expose `4317` explicitly (`otlp-collector` in `telemetry`).
- **`ReferenceGrant`** — the `ListenerPolicy` lives in `kgateway-system` and the
  collector in `telemetry`; the cross-namespace `backendRef` needs a grant.
- **`ListenerPolicy`** — `spec.default.httpSettings.accessLog[].openTelemetry`, pointing
  its `grpcService.backendRef` at `otlp-collector:4317`, with `logName` set and the
  request attributes (`subject`, `method`, `route`, `status`, `id`) mapped from Envoy
  operators. This is the non-deprecated policy (`HTTPListenerPolicy` is deprecated).

## Notes

- **Off the request path.** Metering reads the access log, so the collector or OpenMeter
  can be down without affecting live traffic. Events queue and retry, and OpenMeter
  deduplicates on `(source, id)`.
- **Self-hosted target.** The collector's native `openmeter` output posts to
  `/api/v1/events`, which matches self-hosted OpenMeter.
- **Spoof-safe identity.** The billed `subject` comes from `x-customer-id` here to keep the
  demo simple; to bill the authenticated identity, validate a JWT at the gateway with
  kgateway's native `jwtAuth` + a `GatewayExtension` whose `claimsToHeaders` copies the
  verified `sub` claim into `x-customer-id`. Nothing downstream changes. Inline JWKS works,
  so no identity provider is needed to try it. (Config in the lab page, not run here.)
