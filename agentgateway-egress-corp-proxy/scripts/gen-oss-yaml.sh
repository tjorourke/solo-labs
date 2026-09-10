#!/usr/bin/env bash
# gen-oss-yaml.sh — derive yaml-oss/ from yaml/.
#
# The OSS conversion really is only a group and kind swap plus the GatewayClass.
# spec.static, spec.policies.tls.caCertificateRefs and spec.policies.tunnel are
# field-for-field identical in both editions, so generating the OSS manifests
# rather than maintaining a second copy keeps that claim honest.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SRC="$SCRIPT_DIR/../yaml"
DST="$SCRIPT_DIR/../yaml-oss"
mkdir -p "$DST"

for f in "$SRC"/*.yaml; do
  base="$(basename "$f")"
  # 21-mitmproxy and 10-upstream and 20-squid are plain Kubernetes, not gateway
  # resources: copy them through untouched.
  sed \
    -e 's|^apiVersion: enterpriseagentgateway\.solo\.io/v1alpha1$|apiVersion: agentgateway.dev/v1alpha1|' \
    -e 's|kind: EnterpriseAgentgatewayBackend|kind: AgentgatewayBackend|' \
    -e 's|kind: EnterpriseAgentgatewayParameters|kind: AgentgatewayParameters|' \
    -e 's|group: enterpriseagentgateway\.solo\.io|group: agentgateway.dev|' \
    -e 's|gatewayClassName: enterprise-agentgateway|gatewayClassName: agentgateway|' \
    -e 's|nodePort: 30080|nodePort: 30081|' \
    "$f" > "$DST/$base"
done
ok "yaml-oss/ regenerated from yaml/"
