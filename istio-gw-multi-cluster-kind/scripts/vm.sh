#!/usr/bin/env bash
# Build a persistent "VM" container on the kind network with Docker pre-installed.
# Simulates a bare-metal VM for mesh onboarding exercises.
set -Eeuo pipefail

IMAGE=vm-with-docker

docker build -t "$IMAGE" - <<'EOF'
FROM ubuntu:22.04
RUN apt-get update -qq && \
    apt-get install -y -qq curl ca-certificates iproute2 iputils-ping && \
    curl -fsSL https://get.docker.com | sh && \
    rm -rf /var/lib/apt/lists/*
EOF

docker rm -f vm1 2>/dev/null || true

docker run -d \
  --name vm1 \
  --network kind \
  --privileged \
  --hostname vm1 \
  "$IMAGE" \
  sh -c "dockerd --storage-driver=vfs > /var/log/dockerd.log 2>&1 & sleep infinity"

echo "VM ready. Connect with:"
echo "  docker exec -it vm1 bash"
