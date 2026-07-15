#!/usr/bin/env bash
# 03-images.sh — build the two lab images and load them into kind. Both are
# referenced with imagePullPolicy: IfNotPresent and a :dev tag, so kind never
# tries to pull them from a registry.
#
#   record-tools:dev  — the MCP server that holds the Diagnosis contract
#   dba-adk:dev       — the BYO Google ADK DBA (pydantic output_schema)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check_docker

step "Building record-tools ($RECORD_TOOLS_IMAGE)"
docker build -t "$RECORD_TOOLS_IMAGE" "$LAB_ROOT/images/record-tools" >/dev/null
ok "built $RECORD_TOOLS_IMAGE"

step "Building dba-adk ($DBA_ADK_IMAGE) on kagent-adk:$KAGENT_ADK_VERSION"
docker build --build-arg VERSION="$KAGENT_ADK_VERSION" \
  -t "$DBA_ADK_IMAGE" "$LAB_ROOT/images/dba-adk" >/dev/null
ok "built $DBA_ADK_IMAGE"

step "Loading images into kind '$CLUSTER_NAME'"
kind load docker-image "$RECORD_TOOLS_IMAGE" --name "$CLUSTER_NAME" >/dev/null
kind load docker-image "$DBA_ADK_IMAGE" --name "$CLUSTER_NAME" >/dev/null
ok "both images loaded"

step "Images ready"; echo "  Next: ./scripts/04-agents.sh" >&2
