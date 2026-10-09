# Agent Substrate with fewer host privileges

A standalone, OSS Substrate v0.4.0 lab. Compare the upstream runtime defaults
with a reduced gVisor profile on a dedicated kind worker node. Test snapshots,
memory and file persistence, another UID's file ownership, actor capabilities,
HTTP egress and replacement worker pods. No model API key is needed.

## Run

Prerequisites: Docker, kind, kubectl, Helm 3+, Git, Go 1.26+ and Python 3.10+.
Allow about 8 CPUs and 12 GB available memory. The first run builds the pinned
upstream Go images and downloads gVisor. Internet access is required.

```bash
./scripts/quick.sh up        # fresh cluster, baseline, profile, hardening, tests
./scripts/quick.sh test      # repeat lifecycle, placement and replacement checks
./scripts/quick.sh negative  # expected failures, then restore the working profile
./scripts/quick.sh review    # retain an actor for manual requests; print access commands
./scripts/quick.sh teardown  # delete only this lab's cluster and registry
```

For the step-by-step route, run `prepare`, `install`, `baseline`, `profile`,
`harden`, then `test` instead of `up`. Every kubectl/Helm call uses the lab's own
`.runtime/kubeconfig`. Your current context is not changed.

The cluster is `substrate-least-privilege`. Its registry uses localhost:5507.
The cluster stays running after up, test and negative. Teardown is a separate,
explicit command; keep it running while reviewing or adjusting the configuration.
The runtime node is labelled `lab.mastertheagent.com/pool=runtime` and tainted
`ate.dev/sandboxClass=gvisor:NoSchedule`. Another worker is labelled `general`.

## What the Helm chart does

`charts/runtime-policy` is **this lab's chart**, not an upstream Substrate chart.
It creates a WorkerPool and ServiceAccount. With `yaml/hardened-values.yaml`,
it also installs a Kubernetes MutatingAdmissionPolicy for only that pool's
new worker Pods in `substrate-lab`. It leaves the Substrate controller running
with its normal RBAC. The policy replaces the worker container's capabilities
and seccomp setting at admission, so controller reconciliation cannot undo it.

The upstream runtime is installed using the pinned v0.4.0 `ate-setup` installer.
That build was not published as a matching kagent-distributed Helm chart when
this lab was written. Do not point an older chart at new images and assume its
RBAC, certificates, flags and host paths match.

`yaml/atelet-hardened-patch.yaml` is the gVisor-only node-daemon overlay. It keeps
the `/var/lib/ate` host mount and drops CSI/device-plugin mounts. It is unsuitable
for a pool that also needs CSI, microVM device advertisement or node registry
credential plugins without restoring the corresponding configuration.

## Scope of the minimum

The nine worker capabilities are a measured profile for the tested Linux,
containerd, architecture and gVisor versions, not a universal minimum. UID 0,
SYS_ADMIN and writable node storage remain. AppArmor stays Unconfined; the
local arm64 host does not enforce AppArmor. The optional `portable-values.yaml`
keeps MKNOD for runtimes that require it for image whiteouts.

`profiles/containerd-2.2-arm64.json` is the profile validated with this lab on
arm64, containerd 2.2.0 and the Linux version recorded in the page footer. Copy
it to `.runtime/seccomp/substrate-worker.json` for that environment. It is not
an amd64 profile. The `profile` command remains available for adapting the lab
to a different node image.

The generated local seccomp profile is the node runtime's own default profile,
with pivot_root allowed. It is captured using a harmless sleeping probe with
the upstream worker capability set, then mounted onto the runtime node through
kind's extraMounts. It is not a hand-written allow-all profile. Production nodes
need their own validated profile installed through node-image/config management.

This lab does not install kagent or an Enterprise-specific runtime. Only the
standalone OSS Substrate build is claimed as tested. Kubernetes node privilege
and actor privilege are separate: the actor HTTP probe runs with drop ALL.

## Evidence

Fresh results go to `.runtime/results/`. Published, sanitised results live in
`captures/`. `scripts/lab.py` is the executable guide; `probe/main.go` is the
stateful actor and egress fixture. `scripts/quick.sh` is the fleet entry point.
