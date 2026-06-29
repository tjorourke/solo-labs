#!/usr/bin/env bash
# Tear everything down. Destroys the OpenShift cluster (and all the AWS
# resources it created, including the Route53 records and operator IAM users),
# then reminds you to delete the dedicated installer IAM user.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
"$HERE/bin/openshift-install" destroy cluster --dir "$HERE/cluster" --log-level=info
echo
echo "Now delete the dedicated installer IAM user you created for mint-mode creds:"
echo "  aws iam list-access-keys --user-name ocp-installer"
echo "  aws iam delete-access-key  --user-name ocp-installer --access-key-id <id>"
echo "  aws iam detach-user-policy --user-name ocp-installer --policy-arn arn:aws:iam::aws:policy/AdministratorAccess"
echo "  aws iam delete-user        --user-name ocp-installer"
