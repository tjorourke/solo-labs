# istio-ambient-poc-eks

**A quick-start POC for Istio ambient across two EKS clusters and a VM, on Solo Enterprise for Istio: in-cluster mTLS, EKS to EKS over flat-network peering (cross-cluster data pod IP to pod IP, single HBONE), VM enrolment, an app that bypasses Linux networking, observability, certificate rotation.**

The walkthrough is the lab page (`index.html`), published at
[masterthemesh.com](https://www.masterthemesh.com/solo/istio-ambient-poc-eks/). Every
command on the page is meant to be typed as shown. The scripts in `scripts/` run the
same commands in order and exist so the whole lab can be re-validated end to end.

- **Edition:** Enterprise (multicluster peering, VM onboarding and the Gloo UI need a
  Solo Enterprise for Istio licence).
- **Cloud:** AWS, one region, two VPCs (peered), two EKS clusters, one EC2 VM.
  **Billed infrastructure**: run `scripts/teardown.sh` when done.

## What it covers

| Step | POC question | Where it is proven |
|---|---|---|
| 1 | Install Solo ambient by Helm with a shared root CA | `scripts/01-istio.sh` |
| 2 | Link the two clusters (east-west gateways on internal NLBs) | `scripts/02-peering.sh` |
| 4 | In-cluster mTLS in EKS: identities, STRICT, L4 policy | `scripts/04-mtls.sh` |
| 5 | EKS to EKS cross-cluster: global hostname, failover, cross-cluster policy | `scripts/05-crosscluster.sh` |
| 6 | VM enrolment to EKS: `istioctl vm add-workload`, ztunnel on the VM | `scripts/06-vm.sh` |
| 7 | Custom app that bypasses Linux networking: hostNetwork vs explicit SOCKS5 identity | `scripts/07-bypass.sh` |
| 8 | Monitoring and observability: Gloo UI across both clusters, ztunnel metrics | `scripts/08-observability.sh` |
| 9 | Certificate rotation: intermediate CA rotation under load | `scripts/09-certs.sh` |

"Bare metal Kubernetes to EKS" is not built here (no bare metal in this environment).
The page explains why the east-west gateway pattern is the same and points at NodePort
peering for clusters without a load balancer.

## Never run this against the wrong AWS account

Every AWS-touching script requires `LAB_AWS_PROFILE` set **explicitly** and overrides
`AWS_PROFILE` with it, because sourcing a secrets file can silently export a different
profile.

## Run it

```bash
export LAB_AWS_PROFILE=<your aws profile>
export SOLO_ISTIO_LICENSE_KEY=<your Solo Enterprise for Istio licence>

# 0. infrastructure (about 20 min): two VPCs + peering, two EKS clusters, the VM
cd tofu && AWS_PROFILE=$LAB_AWS_PROFILE tofu init && AWS_PROFILE=$LAB_AWS_PROFILE tofu apply && cd ..

# 1. the lab, in order
./scripts/00-kubeconfig.sh
./scripts/01-istio.sh          # Solo ambient on both clusters, shared root CA
./scripts/02-peering.sh        # east-west gateways + istioctl multicluster link
./scripts/03-app.sh            # frontend + catalog in both clusters
./scripts/04-mtls.sh           # scenario: in-cluster mTLS
./scripts/05-crosscluster.sh   # scenario: EKS to EKS
./scripts/06-vm.sh             # scenario: VM enrolment
./scripts/07-bypass.sh         # scenario: app that bypasses Linux networking
./scripts/08-observability.sh  # scenario: Gloo UI + metrics
./scripts/09-certs.sh          # scenario: certificate rotation

# or all of the above:
./scripts/run-all.sh

# 2. tear it ALL down (billed infra)
./scripts/teardown.sh
```

`scripts/lib.sh` downloads the Solo distribution of `istioctl` matching the mesh
version into `.state/bin/` if the one on your PATH does not match. The generated CA
material and VM tokens also live under `.state/` (gitignored).

## Layout

```
tofu/       OpenTofu: two VPCs, peering, two EKS clusters, the VM (SSM access only)
scripts/    one script per step, same commands as the page
yaml/       every manifest and Helm values file the page applies
```
