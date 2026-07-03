#!/usr/bin/env bash
# Install the OpenMeter benthos-collector (native OTLP -> openmeter output),
# expose 4317, and attach the kgateway OTLP access-log policy.
source "$(dirname "$0")/lib.sh"
step "Installing OpenMeter collector ${COLLECTOR_VERSION}"
helm --kube-context "$CTX" upgrade -i opentelemetry-collector \
  oci://ghcr.io/openmeterio/helm-charts/benthos-collector --version "$COLLECTOR_VERSION" \
  -n telemetry --create-namespace -f "${ROOT}/yaml/collector-values.yaml" --wait
step "Exposing collector on 4317 + ReferenceGrant"
k apply -f "${ROOT}/yaml/04-collector-service.yaml"
step "Attaching the kgateway OTLP access-log policy"
k apply -f "${ROOT}/yaml/03-listenerpolicy.yaml"
sleep 4
k -n kgateway-system get listenerpolicy metering-accesslog \
  -o jsonpath='{range .status.ancestors[*]}{.conditions[*].type}={.conditions[*].status} {end}{"\n"}'
