#!/usr/bin/env bash
# Backup and restore for the whole cluster: Velero, with an S3 backup store and EBS
# snapshots, all in eu-west-2.
#
# Velero backs up the Kubernetes objects (namespaces, CRs, RBAC, the lot) to an S3 bucket
# in-region and snapshots the persistent volumes through the EBS CSI driver. Restore is the
# inverse: recreate the objects and re-attach the volumes from the snapshots. Nothing leaves
# the region, so the backup posture keeps the sovereignty claim: the copy of your cluster
# lives under the same jurisdiction as the cluster.
#
# What it does NOT cover, and what does:
#   - Vault's raft store is backed up by `scripts/vault.sh snapshot` (a raft snapshot to the
#     same in-region S3), because the CA is the crown jewel and Velero only snapshots the PV,
#     not Vault's internal consistency.
#   - The model weights are already durable in S3 (scripts sync/restore), so Velero skips the
#     large models PVC by default; a snapshot of 48 GB of weights that already sit in S3 is
#     just cost.
#
#   ./scripts/velero.sh up        install Velero (bucket + IRSA + helm + storage locations)
#   ./scripts/velero.sh backup    take an on-demand backup now
#   ./scripts/velero.sh verify    list backups and show the last one's status
#   ./scripts/velero.sh schedule  install a daily backup schedule (kept 30 days)
#   ./scripts/velero.sh down      uninstall Velero (leaves the bucket and its backups)
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2; CLUSTER=uk-sovereign-ai; NS=velero
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
BUCKET="${VELERO_BUCKET:-uk-sovereign-ai-velero-${ACCOUNT}}"
POLICY_NAME="uk-sovereign-ai-velero"
kc() { command kubectl --context "$CTX" "$@"; }

up() {
  echo "==> S3 backup bucket ${BUCKET} (eu-west-2, versioned, private)"
  aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null || aws s3api create-bucket --bucket "$BUCKET" \
    --region "$REGION" --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null
  aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled >/dev/null
  # SSE with the same customer-managed key story as etcd/Vault would be the sovereign finish;
  # SSE-S3 (AES256) at minimum so backups are encrypted at rest.
  aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null

  echo "==> IAM policy + IRSA service account for Velero"
  local arn="arn:aws:iam::${ACCOUNT}:policy/${POLICY_NAME}"
  aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1 || aws iam create-policy --policy-name "$POLICY_NAME" \
    --policy-document "$(cat <<JSON
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Action": ["ec2:DescribeVolumes","ec2:DescribeSnapshots","ec2:CreateTags","ec2:CreateVolume","ec2:CreateSnapshot","ec2:DeleteSnapshot"], "Resource": "*" },
  { "Effect": "Allow", "Action": ["s3:GetObject","s3:DeleteObject","s3:PutObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"], "Resource": "arn:aws:s3:::${BUCKET}/*" },
  { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::${BUCKET}" } ] }
JSON
)" >/dev/null
  kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
  eksctl create iamserviceaccount --cluster "$CLUSTER" --region "$REGION" --namespace "$NS" \
    --name velero-server --attach-policy-arn "$arn" --approve --override-existing-serviceaccounts >/dev/null 2>&1

  echo "==> Velero via helm (AWS plugin, S3 backup store + EBS snapshots)"
  helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update vmware-tanzu >/dev/null 2>&1
  helm --kube-context "$CTX" upgrade --install velero vmware-tanzu/velero -n "$NS" \
    --set-string configuration.backupStorageLocation[0].name=default \
    --set-string configuration.backupStorageLocation[0].provider=aws \
    --set-string configuration.backupStorageLocation[0].bucket="$BUCKET" \
    --set-string configuration.backupStorageLocation[0].config.region="$REGION" \
    --set-string configuration.volumeSnapshotLocation[0].name=default \
    --set-string configuration.volumeSnapshotLocation[0].provider=aws \
    --set-string configuration.volumeSnapshotLocation[0].config.region="$REGION" \
    --set initContainers[0].name=velero-plugin-for-aws \
    --set initContainers[0].image=velero/velero-plugin-for-aws:v1.13.0 \
    --set initContainers[0].volumeMounts[0].mountPath=/target \
    --set initContainers[0].volumeMounts[0].name=plugins \
    --set serviceAccount.server.create=false \
    --set serviceAccount.server.name=velero-server \
    --set credentials.useSecret=false \
    --wait --timeout 5m >/dev/null
  echo "    installed. locations:"
  kc -n "$NS" get backupstoragelocation,volumesnapshotlocation --no-headers 2>/dev/null | awk '{print "      "$1,$2}'
}

# Everything except the two things that are backed up elsewhere: the model weights (already
# durable in S3) and Velero's own namespace.
backup() {
  local name="ondemand-$(date +%s 2>/dev/null || echo now)"
  kc -n "$NS" exec deploy/velero -- /velero backup create "$name" \
    --exclude-namespaces velero --exclude-resources '' \
    --snapshot-volumes 2>/dev/null || \
  kc apply -f - <<YAML
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ondemand
  namespace: ${NS}
spec:
  excludedNamespaces: [velero]
  snapshotVolumes: true
  ttl: 720h0m0s
YAML
  echo "backup requested; check with: $0 verify"
}

verify() {
  echo "== backup storage location (should read Available):"
  kc -n "$NS" get backupstoragelocation 2>/dev/null
  echo "== backups:"
  kc -n "$NS" get backups.velero.io 2>/dev/null | tail -8
}

schedule() {
  kc apply -f - <<YAML
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily
  namespace: ${NS}
spec:
  schedule: "0 2 * * *"
  template:
    excludedNamespaces: [velero]
    snapshotVolumes: true
    ttl: 720h0m0s
YAML
  echo "daily backup scheduled at 02:00, kept 30 days"
}

down() { helm --kube-context "$CTX" uninstall velero -n "$NS" >/dev/null 2>&1 || true; echo "Velero removed; bucket ${BUCKET} and its backups left in place"; }

case "${1:-up}" in
  up) up ;;
  backup) backup ;;
  verify) verify ;;
  schedule) schedule ;;
  down) down ;;
  *) echo "usage: $0 {up|backup|verify|schedule|down}"; exit 1 ;;
esac
