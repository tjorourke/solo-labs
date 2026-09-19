#!/usr/bin/env bash
# Optional: publish the gateway and the Enterprise UI on real hostnames with real
# certificates. Everything else in this lab is ClusterIP and a port-forward, and the
# flow, the controls and scripts/06 to 09 all run without this.
#
#   ./scripts/platform/40-public-endpoints.sh            plan, then apply
#   ./scripts/platform/40-public-endpoints.sh plan       show what would change
#   ./scripts/platform/40-public-endpoints.sh destroy    take the names and the ELBs away
#   ./scripts/platform/40-public-endpoints.sh refresh-ip put your current address back on the UI
#   ./scripts/platform/40-public-endpoints.sh adopt      take over endpoints made by hand
#
# You need this for one reason: a real editor. Cursor sends its chat completions from
# Cursor's own backend rather than from the laptop, so the endpoint has to be reachable
# from the internet with a certificate a browser trusts. A port-forward serves curl and
# nothing else.
#
# What it creates, all of it in tofu/:
#   - an ACM certificate per name, DNS-validated in an existing Route53 zone
#   - a LoadBalancer Service in front of the intake gateway, and one in front of the UI
#   - a CNAME per name pointing at the ELB that came back
#
# The Route53 zone is read, not created. Point ZONE at a zone that already exists and is
# already delegated.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOFU_DIR="$HERE/tofu"
cd "$TOFU_DIR"

command -v tofu >/dev/null || { echo "tofu not found: https://opentofu.org/docs/intro/install/" >&2; exit 1; }

ZONE="${ZONE:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
REGION="${AWS_REGION:-eu-west-2}"

[ -n "$ZONE" ] || {
  cat >&2 <<EOF
ZONE is not set. Name the Route53 hosted zone to publish under, for example:

  ZONE=awslab.example.com $0

It has to exist already: the zone is delegated from its parent, and one created here
would have new nameservers that nothing points at.
EOF
  exit 1
}

# The UI has no request authentication in front of it, so it is published to your own
# address and nothing else. Detecting it here rather than asking is what stops the value
# going stale: a dynamic address moves, the security group keeps allowing the old one,
# and the browser reports a timeout with nothing in any cluster log to explain it.
MY_IP="${MY_IP:-$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')}"
[ -n "$MY_IP" ] || { echo "could not work out your public address; set MY_IP=x.x.x.x" >&2; exit 1; }

UI_CIDRS="${UI_CIDRS:-$MY_IP/32}"
# Comma-separated in, HCL list out.
UI_LIST="[$(echo "$UI_CIDRS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | awk 'NF{printf "%s\"%s\"", (NR>1?",":""), $0}')]"

tf() {
  tofu "$@" \
    -var "aws_region=$REGION" \
    -var "kube_context=$KUBE_CONTEXT" \
    -var "route53_zone_name=$ZONE" \
    -var "ui_allowed_cidrs=$UI_LIST"
}

cat <<EOF

  zone        $ZONE
  context     $KUBE_CONTEXT
  region      $REGION
  UI open to  $UI_CIDRS

EOF

[ -d .terraform ] || tofu init -input=false

case "${1:-apply}" in
  plan)
    tf plan
    ;;
  destroy)
    # The Services go with it, so the ELBs go with it. Check afterwards: a classic ELB
    # left behind is not visible in the elbv2 API that most sweeps use.
    tf destroy
    echo
    echo "Check nothing survived:"
    echo "  aws elb describe-load-balancers --region $REGION --query 'LoadBalancerDescriptions[].DNSName'"
    ;;
  refresh-ip)
    # The common case by a distance: same cluster, same names, new address.
    tf apply -auto-approve -target=kubernetes_service.ui_public
    echo
    echo "UI now open to $UI_CIDRS"
    ;;
  adopt)
    # For a cluster whose endpoints were made by hand before this file existed. Imports
    # them into state instead of creating a second set, which is what a plain apply would
    # try: the Service names already exist, so it would fail on the first one and leave
    # the certificates behind.
    #
    # The ACM validation records and the aws_acm_certificate_validation resources are not
    # imported. Validation has already happened, the certificates are ISSUED, and those
    # resources converge on the next apply without touching anything.
    ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$ZONE" \
      --query "HostedZones[?Name=='${ZONE}.'].Id | [0]" --output text | sed 's#/hostedzone/##')"
    [ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "None" ] || { echo "no hosted zone for $ZONE" >&2; exit 1; }

    GW_FQDN="${GW_SUB:-agw}.$ZONE"
    UI_FQDN="${UI_SUB:-soloui}.$ZONE"
    NS="${NS:-agentgateway-system}"

    gw_arn="$(aws acm list-certificates --region "$REGION" \
      --query "CertificateSummaryList[?DomainName=='$GW_FQDN'].CertificateArn | [0]" --output text)"
    ui_arn="$(aws acm list-certificates --region "$REGION" \
      --query "CertificateSummaryList[?DomainName=='$UI_FQDN'].CertificateArn | [0]" --output text)"

    # Already-imported resources are not an error here: adopt is re-runnable, and a
    # half-finished first run is exactly when you want to run it again.
    imp() {
      if tofu state list 2>/dev/null | grep -qx "$1"; then
        printf '  %-40s already in state\n' "$1"
        return 0
      fi
      # Not tf(): that helper appends its -var flags, and tofu import needs every flag
      # ahead of the address and the id.
      if tofu import \
        -var "aws_region=$REGION" \
        -var "kube_context=$KUBE_CONTEXT" \
        -var "route53_zone_name=$ZONE" \
        -var "ui_allowed_cidrs=$UI_LIST" \
        "$1" "$2" >/tmp/agw-import.$$ 2>&1; then
        printf '  %-40s imported\n' "$1"
      else
        printf '  %-40s FAILED\n' "$1"
        sed 's/^/      /' /tmp/agw-import.$$ | tail -6
      fi
      rm -f /tmp/agw-import.$$
    }
    [ "$gw_arn" != "None" ] && imp aws_acm_certificate.gateway "$gw_arn"
    [ "$ui_arn" != "None" ] && imp aws_acm_certificate.ui "$ui_arn"
    imp kubernetes_service.gateway_public "$NS/model-gateway-public"
    imp kubernetes_service.ui_public "$NS/solo-enterprise-ui-public"
    imp aws_route53_record.gateway "${ZONE_ID}_${GW_FQDN}_CNAME"
    imp aws_route53_record.ui "${ZONE_ID}_${UI_FQDN}_CNAME"

    echo
    echo "Imported. Now reconcile the difference between what is running and what this code says:"
    echo "  $0 plan"
    ;;
  apply|"")
    tf apply
    echo
    tofu output
    echo
    cat <<'EOF'
Point Claude Code at it:

  HOST=$(tofu -chdir=tofu output -raw gateway_host) ./scripts/10-claude-code.sh

DNS is a 60s TTL CNAME and ACM has just been validated, so give the name a minute
before the first request.
EOF
    ;;
  *)
    echo "usage: $(basename "$0") [plan|apply|destroy|refresh-ip]" >&2
    exit 2
    ;;
esac
