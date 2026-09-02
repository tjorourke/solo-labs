#!/usr/bin/env bash
# run-all.sh — the whole lab end to end, after `tofu apply`. Needs
# LAB_AWS_PROFILE and SOLO_ISTIO_LICENSE_KEY (or SECRETS_FILE).
cd "$(dirname "${BASH_SOURCE[0]}")"
for s in 00-kubeconfig 01-istio 02-peering 03-app 04-mtls 05-crosscluster 06-vm 07-bypass 08-observability 09-certs; do
  echo; echo "################  $s  ################"; ./$s.sh || { echo "FAILED at $s"; exit 1; }
done
echo; echo "ALL DONE"
