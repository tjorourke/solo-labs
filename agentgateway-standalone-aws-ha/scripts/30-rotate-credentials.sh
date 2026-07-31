#!/bin/bash
# Roll the runtime credentials onto the fleet, one node at a time.
#
# Every credential the gateway uses lives in one Secrets Manager document, and each node
# renders that document into /etc/agentgateway/env at boot. Updating the document
# therefore does not reach a running node on its own: the node has to re-render and the
# gateway has to restart to pick up anything in the startup `config` block.
#
# This script does that in a rolling fashion, waiting for each node to come back healthy
# behind the load balancer before touching the next one, so the fleet keeps serving
# throughout.
#
#   scripts/30-rotate-credentials.sh              roll the current secret onto all nodes
#   scripts/30-rotate-credentials.sh --show       print which keys the secret holds
#
# It does not change any credential at source. Change the password or the key first, put
# the new value in the secret, then run this. The page has the per-credential procedure.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tools; require_aws; require_stack

SECRET_ARN="$(tf_out runtime_secret_arn)"

if [[ "${1:-}" == "--show" ]]; then
  hdr "Keys in the runtime secret"
  log "Values are not printed. This is the shape of the document each node renders."
  aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
    --query SecretString --output text | jq -r 'keys[]' | sed 's/^/    /'
  hdr "Which of these need a restart to take effect"
  cat <<'EOT'
  Needs a gateway restart, because it is read from the startup config block:
    SESSION_KEY          AGW_DATABASE_URL     OIDC_COOKIE_SECRET
    OTLP_ENDPOINT        RATELIMIT_HOST

  Picked up on the next request, because the policies that use it reload with the file:
    OPENAI_API_KEY       ANTHROPIC_API_KEY    COGNITO_UI_CLIENT_SECRET
    COGNITO_ISSUER       COGNITO_JWKS_URL     BEDROCK_GUARDRAIL_ID
    AGW_PUBLIC_URL       COGNITO_API_AUDIENCE

  The second group still needs the node to re-render its env file, which is a restart in
  practice, because the env file is only read when the process starts.
EOT
  exit 0
fi

hdr "Rolling the runtime secret onto the fleet"
log "secret: $SECRET_ARN"
log "This restarts the gateway on each node in turn. Two of three stay in service."
echo

# The re-render is done inline over SSM rather than from a node-side helper, so this works
# on a node built before the script existed.
render_and_restart() { # render_and_restart <instance-id>
  node_exec "$1" "set -euo pipefail
tmp=\$(mktemp)
aws secretsmanager get-secret-value --secret-id '$SECRET_ARN' --region '$AWS_REGION' \
  --query SecretString --output text \
| jq -r 'to_entries[] | \"\\(.key)=\\(.value | tostring | @sh)\"' > \"\$tmp\"
TOKEN=\$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
IID=\$(curl -sf -H \"X-aws-ec2-metadata-token: \$TOKEN\" http://169.254.169.254/latest/meta-data/instance-id)
AZ=\$(curl -sf -H \"X-aws-ec2-metadata-token: \$TOKEN\" http://169.254.169.254/latest/meta-data/placement/availability-zone)
IP=\$(curl -sf -H \"X-aws-ec2-metadata-token: \$TOKEN\" http://169.254.169.254/latest/meta-data/local-ipv4)
{ echo \"AGW_NODE_ID=\$IID\"; echo \"AGW_NODE_AZ=\$AZ\"; echo \"AGW_NODE_IP=\$IP\"; echo 'RUST_LOG=info'; } >> \"\$tmp\"
install -o root -g agentgateway -m 0640 \"\$tmp\" /etc/agentgateway/env
rm -f \"\$tmp\"
systemctl restart agentgateway
for i in \$(seq 1 60); do curl -sf http://127.0.0.1:15021/healthz/ready >/dev/null && break; sleep 1; done
curl -sf http://127.0.0.1:15021/healthz/ready >/dev/null && echo 'ready' || { echo 'NOT READY'; exit 1; }"
}

nodes=(); while read -r i; do nodes+=("$i"); done < <(fleet_instances)
log "fleet: ${nodes[*]}"
echo

for id in "${nodes[@]}"; do
  hdr "Node $id"
  before="$(healthy_count)"
  log "healthy before: $before"

  log "re-rendering /etc/agentgateway/env and restarting the gateway"
  if render_and_restart "$id" | sed 's/^/    /'; then
    ok "gateway reports ready on $id"
  else
    die "node $id did not come back ready; stopping here so the rest of the fleet is untouched"
  fi

  log "waiting for the load balancer to put it back in service"
  for i in $(seq 1 48); do
    h="$(healthy_count)"
    printf '    t+%-3ss healthy=%s\n' $((i*5)) "$h"
    [[ "$h" == "3" ]] && break
    sleep 5
  done
  expect "three healthy targets after $id" 3 "$(healthy_count)"

  log "and the fleet is still answering:"
  for _ in $(seq 1 6); do whoami_node; done | sort | uniq -c | sed 's/^/    /'
  echo
done

hdr "Confirm the new credentials are in use"
# The env file is not identical across nodes and should not be: it carries this node's
# own instance id, zone and address. Compare only the shared lines.
log "Hash of the shared lines, ignoring the per-node identity:"
sums=""
for id in "${nodes[@]}"; do
  h="$(node_try "$id" "grep -v '^AGW_NODE_' /etc/agentgateway/env | sort | sha256sum | cut -c1-12" | tr -d '\n ')"
  printf '  %-20s shared=%s\n' "$id" "${h:-?}"
  sums="$sums$h\n"
done
distinct="$(printf '%b' "$sums" | sort -u | grep -c . | tr -d ' ')"
expect "all nodes hold identical shared credentials" 1 "$distinct"

log "A database-backed feature still works, which exercises the Aurora credential:"
expect "MCP resource metadata" 200 "$(code "$GATEWAY_URL/.well-known/oauth-protected-resource/mcp")"
TOK="$(mint_token all)"
expect "an authenticated request" 200 "$(code -H "authorization: Bearer $TOK" "$GATEWAY_URL/api/private/headers")"

summary
