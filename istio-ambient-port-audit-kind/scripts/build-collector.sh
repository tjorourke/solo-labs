#!/usr/bin/env bash
# build-collector.sh — build the collector image and load it into the kind
# cluster. Separate from setup-cluster.sh so an edit to collector.py is a
# 10-second rebuild + `kubectl rollout restart daemonset/port-audit-collector`.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require docker; require kind; check_docker

IMG="${COLLECTOR_IMAGE:-port-audit-collector:v1}"

step "Building $IMG"
docker build -q -t "$IMG" "$LAB_ROOT/collector" >/dev/null
# Same save/load dance as the Solo images: with Docker's containerd store,
# `kind load docker-image` chokes on the multi-platform index.
tar="$(mktemp)"
docker save --platform "$KIND_PLATFORM" "$IMG" -o "$tar"
kind load image-archive "$tar" --name "$CLUSTER_NAME" >/dev/null
rm -f "$tar"
ok "$IMG built and loaded into kind '$CLUSTER_NAME'"
