#!/usr/bin/env bash
# build.sh: build the Go agent image and push it to the kind registry.
#
# No Go toolchain is needed on the machine: the Dockerfile's build stage has it.
#
#   IMAGE   where to push (default localhost:5001/sre-go:lab, the registry wired into kind)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts/lib.sh"
require docker
IMAGE="${IMAGE:-localhost:5001/sre-go:lab}"

step "Building $IMAGE"
docker build --progress=quiet -t "$IMAGE" "$SCRIPT_DIR/../src" >/dev/null
docker push -q "$IMAGE" >/dev/null
ok "pushed $IMAGE ($(docker image inspect "$IMAGE" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1000000}'))"
