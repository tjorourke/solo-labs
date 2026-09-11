#!/usr/bin/env bash
# build.sh: build the Java agent image and push it to the kind registry.
#
# Maven and the JDK run inside the Docker build, so nothing Java is needed on this
# machine. The tag is fixed and the Agent pulls with imagePullPolicy Always, so after a
# push the running Deployment (if any) is restarted to pick the new image up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts/lib.sh"
IMAGE="${IMAGE:-localhost:5001/sre-java:lab}"

require docker
step "Building $IMAGE (Maven runs in the image)"
docker build --progress=quiet -t "$IMAGE" "$SCRIPT_DIR/../src" >/dev/null
docker push -q "$IMAGE" >/dev/null
ok "pushed $IMAGE"
if kc -n "$NS" get deploy sre-java >/dev/null 2>&1; then
  kc -n "$NS" rollout restart deploy/sre-java >/dev/null
  log "restarted deploy/sre-java to pull the new image"
fi
