#!/usr/bin/env bash
# build.sh: build the agent image and push it to the registry the cluster pulls from.
#
# The tag is fixed and the Agent pulls with imagePullPolicy: Always, so a rebuild is
# picked up by restarting the Deployment, which this does when one exists. The digest
# is printed so a running pod can be compared with what was built.
#
#   IMAGE=localhost:5001/sre-python:lab   override the image reference
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-authoring-contract-kind/scripts/lib.sh
source "$SCRIPT_DIR/../../agent-authoring-contract-kind/scripts/lib.sh"
require docker
IMAGE="${IMAGE:-localhost:5001/sre-python:lab}"

step "Building $IMAGE"
docker build --progress=quiet -t "$IMAGE" "$SCRIPT_DIR/../src" >/dev/null
docker push -q "$IMAGE" >/dev/null
DIGEST="$(docker inspect --format '{{index .RepoDigests 0}}' "$IMAGE" | sed 's/.*@//')"
ok "pushed $IMAGE ($DIGEST)"

if kc -n "$NS" get deploy sre-python >/dev/null 2>&1; then
  step "Restarting the running agent onto the new image"
  kc -n "$NS" rollout restart deploy/sre-python >/dev/null
  kc -n "$NS" rollout status deploy/sre-python --timeout=240s >/dev/null
  RUNNING="$(kc -n "$NS" get pod -l app.kubernetes.io/name=sre-python -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' | sed 's/.*@//')"
  [[ "$RUNNING" == "$DIGEST" ]] && ok "pod runs $RUNNING" || warn "pod runs $RUNNING, built $DIGEST"
fi
