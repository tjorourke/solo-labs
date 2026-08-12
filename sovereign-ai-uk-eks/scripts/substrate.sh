#!/usr/bin/env bash
# gVisor on the sandbox node group, so kagent's Agent Substrate can run agents in a real
# userspace-kernel sandbox rather than a plain container.
#
#   ./scripts/substrate.sh up      installer DaemonSet + gvisor RuntimeClass (sandbox nodes only)
#   ./scripts/substrate.sh test    run a pod under gVisor and prove it is sandboxed
#   ./scripts/substrate.sh status   what is installed and whether nodes are ready
#   ./scripts/substrate.sh down     remove the RuntimeClass + installer
#
# The installer runs ONLY on the tainted sandbox nodes (nodeSelector role=sandbox plus the
# toleration), so it reconfigures containerd there and never touches the platform or GPU
# fleet. That blast-radius containment is deliberate: installing a container runtime is
# invasive, and it has no business running on the node that serves the model.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }

case "${1:-status}" in
  up)
    echo "==> gvisor RuntimeClass + namespace (sandbox nodes only)"
    kc apply -f - <<'YAML'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
# Pods that ask for this RuntimeClass are pinned to the sandbox nodes and tolerate their
# taint, so a gVisor pod cannot accidentally land on a node without runsc installed.
scheduling:
  nodeSelector:
    sandbox.solo.io/runtime: gvisor
  tolerations:
    - key: sandbox.solo.io/gvisor
      value: "true"
      effect: NoSchedule
---
apiVersion: v1
kind: Namespace
metadata:
  name: gvisor-system
  labels:
    pod-security.kubernetes.io/enforce: privileged
YAML

    # The installer script lives in a ConfigMap, not inline in the pod spec: a nested
    # heredoc inside a YAML block scalar is a parse trap, and a mounted script is easier
    # to read and to fix.
    echo "==> installer script ConfigMap"
    kc -n gvisor-system create configmap gvisor-install --dry-run=client -o yaml \
      --from-file=install.sh=/dev/stdin <<'SCRIPT' | kc apply -f - >/dev/null
set -euo pipefail
ARCH=$(uname -m)
URL="https://storage.googleapis.com/gvisor/releases/release/latest/${ARCH}"
if [ ! -x /host/usr/local/bin/runsc ]; then
  echo "installing runsc + shim for ${ARCH}"
  apt-get update -qq && apt-get install -y -qq wget >/dev/null
  cd /tmp
  wget -q "${URL}/runsc" "${URL}/runsc.sha512" "${URL}/containerd-shim-runsc-v1" "${URL}/containerd-shim-runsc-v1.sha512"
  sha512sum -c runsc.sha512 -c containerd-shim-runsc-v1.sha512
  chmod a+rx runsc containerd-shim-runsc-v1
  cp -f runsc containerd-shim-runsc-v1 /host/usr/local/bin/
else
  echo "runsc already present"
fi
CFG=/host/etc/containerd/config.toml
if ! grep -q 'runtimes.runsc' "$CFG"; then
  PREFIX=$(grep -oE "\[plugins\.[^]]*\.containerd\.runtimes\.runc\]" "$CFG" | head -1 | sed 's/\.runc]$//;s/^\[//')
  [ -n "$PREFIX" ] || PREFIX="plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes"
  echo "adding runsc runtime under: $PREFIX"
  printf '\n[%s.runsc]\n  runtime_type = "io.containerd.runsc.v1"\n' "$PREFIX" >> "$CFG"
  echo "restarting containerd on the host"
  nsenter --target 1 --mount --uts --ipc --net --pid -- systemctl restart containerd
else
  echo "containerd already knows runsc"
fi
echo "gvisor ready on $(uname -n); holding"
sleep infinity
SCRIPT

    echo "==> installer DaemonSet"
    kc apply -f - <<'YAML'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: gvisor-installer
  namespace: gvisor-system
spec:
  selector: { matchLabels: { app: gvisor-installer } }
  template:
    metadata: { labels: { app: gvisor-installer } }
    spec:
      nodeSelector: { sandbox.solo.io/runtime: gvisor }
      tolerations:
        - { key: sandbox.solo.io/gvisor, value: "true", effect: NoSchedule }
      hostPID: true
      containers:
        - name: installer
          image: debian:12-slim
          securityContext: { privileged: true }
          command: ["/bin/bash", "/scripts/install.sh"]
          volumeMounts:
            - { name: host, mountPath: /host }
            - { name: script, mountPath: /scripts }
      volumes:
        - name: host
          hostPath: { path: / }
        - name: script
          configMap: { name: gvisor-install }
YAML
    echo "    applied; waiting for the installer to finish on the sandbox node(s)"
    kc -n gvisor-system rollout status ds/gvisor-installer --timeout=300s 2>&1 | tail -1
    sleep 5
    kc -n gvisor-system logs -l app=gvisor-installer --tail=5 2>/dev/null | sed 's/^/    /' | tail -6
    ;;

  test)
    echo "==> running a pod under RuntimeClass gvisor and proving the sandbox"
    kc delete pod gvisor-probe --ignore-not-found >/dev/null 2>&1
    kc run gvisor-probe --image=busybox:1.36 --restart=Never \
      --overrides='{"spec":{"runtimeClassName":"gvisor","containers":[{"name":"p","image":"busybox:1.36","command":["sh","-c","echo === dmesg ===; dmesg 2>/dev/null | head -3; echo === kernel ===; uname -a"]}]}}' >/dev/null
    kc wait --for=condition=ready pod/gvisor-probe --timeout=90s >/dev/null 2>&1 || true
    sleep 3
    # gVisor's dmesg announces itself ("Starting gVisor..."), which a normal container
    # cannot show. That line is the proof the workload is running on the gVisor kernel.
    kc logs gvisor-probe 2>&1 | sed 's/^/    /'
    echo "    node:"
    kc get pod gvisor-probe -o jsonpath='{"    "}{.spec.nodeName}{" runtimeClass="}{.spec.runtimeClassName}{"\n"}'
    kc delete pod gvisor-probe --ignore-not-found >/dev/null 2>&1
    ;;

  status)
    echo "=== sandbox nodes"
    kc get nodes -l role=sandbox -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,RUNTIME:.status.nodeInfo.containerRuntimeVersion' --no-headers 2>/dev/null || echo "  none"
    echo "=== RuntimeClass"
    kc get runtimeclass gvisor 2>/dev/null || echo "  not present"
    echo "=== installer"
    kc -n gvisor-system get ds gvisor-installer 2>/dev/null || echo "  not installed"
    ;;

  down)
    kc delete ds gvisor-installer -n gvisor-system >/dev/null 2>&1 || true
    kc delete runtimeclass gvisor >/dev/null 2>&1 || true
    echo "removed (nodes keep runsc until replaced)"
    ;;

  *) echo "usage: $0 {up|test|status|down}"; exit 1 ;;
esac
