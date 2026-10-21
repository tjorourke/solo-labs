#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
for chart in base istiod cni ztunnel; do
  helm --kube-context "$CTX" upgrade -i "istio-$chart" "$chart" --repo https://istio-release.storage.googleapis.com/charts -n istio-system --create-namespace --version "$ISTIO_VERSION" --set profile=ambient --wait --timeout=5m
done
k label namespace bank istio.io/dataplane-mode=ambient --overwrite
apply "$LAB/yaml/mesh.yaml"
