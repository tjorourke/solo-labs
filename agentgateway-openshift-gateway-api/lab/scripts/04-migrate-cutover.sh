#!/usr/bin/env bash
# Migrate the live app from OpenShift's gateway to agentgateway with zero
# downtime: stand agentgateway up alongside, attach the same route to both,
# then swap DNS. The old gateway stays up through the cutover, so no gap.
#
# Prereqs: KUBECONFIG set; source ../env.sh (APP_HOST, BASE_DOMAIN); agentgateway
# installed (script 03); sample app running (script 01); monitor running (02).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; Y="$HERE/yaml"
: "${APP_HOST:?}"; : "${BASE_DOMAIN:?}"; export APP_HOST

# 1. agentgateway Gateway (enterprise-agentgateway class), in the app namespace.
oc apply -f "$Y/40-agentgateway-gateway.yaml"

# 2. SCC fix: the agentgateway PROXY pod runs as UID 10101, which restricted-v2
#    rejects ("runAsUser: Invalid value: 10101: must be in the ranges ..."), so
#    the proxy ReplicaSet can't create pods. Grant the gateway's service account
#    (named after the gateway) anyuid, then roll the proxy.
SA=$(oc -n gwtest get deploy hello-agw -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || echo hello-agw)
oc adm policy add-scc-to-user anyuid -z "${SA:-hello-agw}" -n gwtest
oc -n gwtest rollout restart deploy/hello-agw 2>/dev/null || true
echo "waiting for agentgateway proxy + LB..."
until [ -n "$(oc -n gwtest get svc hello-agw -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)" ] \
   && [ "$(oc -n gwtest get deploy hello-agw -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ]; do sleep 8; done
AGW_LB="$(oc -n gwtest get svc hello-agw -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

# 3. Cross-zone LB (same 2-worker/3-AZ reason as the OpenShift gateway).
oc -n gwtest annotate svc hello-agw \
  service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled=true --overwrite

# 4. Attach the route to BOTH gateways (idempotent: 30-httproute.yaml already
#    lists both parents). Now both LBs serve the app.
envsubst < "$Y/30-httproute.yaml" | oc apply -f -

# 5. Verify agentgateway serves before cutover.
until curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Host: ${APP_HOST}" "http://$AGW_LB/" | grep -q 200; do sleep 8; done
echo "agentgateway serving OK ($AGW_LB)"

# 6. DNS cutover: point APP_HOST at the agentgateway LB. Old gateway stays up,
#    so the monitor should show continuous 200s through the flip.
ZONE=$(aws route53 list-hosted-zones-by-name --dns-name "${BASE_DOMAIN}." \
        --query 'HostedZones[0].Id' --output text | sed 's#/hostedzone/##')
cat > /tmp/r53cut.json <<EOF
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"${APP_HOST}","Type":"CNAME","TTL":30,"ResourceRecords":[{"Value":"$AGW_LB"}]}}]}
EOF
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch file:///tmp/r53cut.json
echo "cutover submitted. Watch evidence/availability.log flip OPENSHIFT-gw -> AGENTGATEWAY with fail=0."

# 7. (Optional, after the flip settles) decommission the OpenShift gateway:
#    oc -n openshift-ingress delete gateway hello-gw
#    and remove its parentRef from the HTTPRoute.
