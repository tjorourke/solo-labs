#!/usr/bin/env bash
# Kernwerk data protection: three routes out of one gateway, on the
# model-routing cluster.
#
#   public   Claude, from Anthropic
#   eu       Claude on Amazon Bedrock, EU inference profile (EU regions only)
#   private  Mistral Small on the cluster's own GPUs (vllm in namespace models)
#
# The gateway assumes an IAM role that may invoke the EU inference profile and
# nothing else. Personal data is found and replaced by kernwerk-pii, which runs
# in the cluster, so no prompt is sent to a cloud service to be checked.
#
#   AWS_PROFILE=<profile> ./up.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLUSTER="${CLUSTER:-model-routing}"
CLUSTER_REGION="${CLUSTER_REGION:-eu-west-2}"
CTX="${KUBE_CONTEXT:-$(kubectl config get-contexts -o name | grep "cluster/$CLUSTER\$" || kubectl config current-context)}"
PROFILE_REGION=eu-central-1
PROFILE=eu.anthropic.claude-sonnet-5
ROLE=kernwerk-dlp-gateway

ACCT=$(aws sts get-caller-identity --query Account --output text)

OIDC=$(aws eks describe-cluster --name "$CLUSTER" --region "$CLUSTER_REGION" \
  --query cluster.identity.oidc.issuer --output text | sed 's#^https://##')
# Two gateways reach the EU model and so two service accounts assume this role: dlp-gateway
# for the Kernwerk data-protection routes, and decision-gateway for the eu-hosted pool the
# task router sends a Class 2 request to. Named individually rather than by wildcard, so
# the role stays readable in an audit: these two, and nothing else in the namespace.
TRUST=$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Federated":"arn:aws:iam::$ACCT:oidc-provider/$OIDC"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{"StringEquals":{"$OIDC:aud":"sts.amazonaws.com"},
              "ForAnyValue:StringEquals":{"$OIDC:sub":["system:serviceaccount:agentgateway-system:dlp-gateway","system:serviceaccount:agentgateway-system:decision-gateway"]}}}]}
JSON
)
aws iam create-role --role-name $ROLE --assume-role-policy-document "$TRUST" >/dev/null 2>&1 \
  || aws iam update-assume-role-policy --role-name $ROLE --policy-document "$TRUST"
# The inference profile, and the model behind it in EU regions only.
aws iam put-role-policy --role-name $ROLE --policy-name invoke-eu-model --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],
 "Resource":["arn:aws:bedrock:$PROFILE_REGION:$ACCT:inference-profile/$PROFILE",
             "arn:aws:bedrock:eu-*::foundation-model/anthropic.claude-sonnet-5"]}]}
JSON
)"

export ROLE_ARN="arn:aws:iam::$ACCT:role/$ROLE"
# The three classes are defined once, in the task router's opa/routing-data.json, because
# AGW enforces the same classes on the decision gateway and the two must not drift. Read
# them from there and escape the backslashes for the CEL string literal they land in.
TASK_ROUTER="${TASK_ROUTER:-$HERE/../../../../agentgateway-inference-task-routing-eks}"
DATA_CLASSES="${DATA_CLASSES:-$TASK_ROUTER/opa/routing-data.json}"
[ -f "$DATA_CLASSES" ] || { echo "no $DATA_CLASSES; install the task-routing lab first, or set TASK_ROUTER" >&2; exit 1; }
pattern_for() {
  python3 - "$1" "$DATA_CLASSES" <<'PY'
import json, sys
name, path = sys.argv[1], sys.argv[2]
for c in json.load(open(path))["dlp"]["data_classes"]:
    if c["class"] == name:
        print(c["pattern"].replace("\\", "\\\\"))
        break
else:
    raise SystemExit("no data class %r in %s" % (name, path))
PY
}
export CLASS_3_PATTERN="$(pattern_for private)"
export CLASS_2_PATTERN="$(pattern_for eu)"
# Claude Desktop signs in to the model gateway with keys the task-routing lab
# made, so its route takes the same two providers.
export JWT_PROVIDERS=$(kubectl --context "$CTX" -n agentgateway-system get enterpriseagentgatewaypolicy classify \
  -o jsonpath='{.spec.traffic.jwtAuthentication.providers}')
for f in "$HERE"/0*.yaml "$HERE"/0*.yaml.tmpl; do
  envsubst '${ROLE_ARN} ${JWT_PROVIDERS} ${CLASS_2_PATTERN} ${CLASS_3_PATTERN}' < "$f" | kubectl --context "$CTX" apply -f -
done
# The service account annotation only reaches pods started after it, and
# kernwerk-pii only reads its script when it starts.
# The task router's decision gateway answers the eu-hosted pool from the same Bedrock
# profile, so it needs the same role. The annotation is added here rather than in that
# lab's Gateway, which would make it depend on an IAM role it never creates. Without it the
# pod uses the node's own identity and a Class 2 request comes back as an AWS authorisation
# error instead of an answer.
if kubectl --context "$CTX" -n agentgateway-system get sa decision-gateway >/dev/null 2>&1; then
  kubectl --context "$CTX" -n agentgateway-system annotate serviceaccount decision-gateway \
    "eks.amazonaws.com/role-arn=$ROLE_ARN" --overwrite >/dev/null
  kubectl --context "$CTX" -n agentgateway-system rollout restart deploy/decision-gateway >/dev/null
  WAIT_FOR="dlp-gateway wire-tap kernwerk-pii decision-gateway"
else
  echo "note: no decision-gateway here, so the eu-hosted pool has no model. Install agentgateway-inference-task-routing-eks."
  WAIT_FOR="dlp-gateway wire-tap kernwerk-pii"
fi
kubectl --context "$CTX" -n agentgateway-system rollout restart deploy/dlp-gateway deploy/kernwerk-pii >/dev/null 2>&1 || true
for d in $WAIT_FOR; do
  kubectl --context "$CTX" -n agentgateway-system rollout status deploy/$d --timeout=300s
done
kubectl --context "$CTX" -n models get deploy vllm >/dev/null \
  || echo "note: no vllm in namespace models, so the private route has no model. Run gpu.sh up in agentgateway-inference-model-routing-eks."
