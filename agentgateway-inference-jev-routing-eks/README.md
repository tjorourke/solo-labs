# Prompt-aware model routing, Part 5: Jev classification with agentgateway

**Knowledge-base implementation guide, not a live-validated EKS lab.**
The companion article is at
https://mastertheagent.com/solo/agentgateway-inference-jev-routing-eks/.

This reference implementation calls TypeSafe's Jev API from an Envoy v3 ExtProc
adapter. Questions, choices, thresholds, fallback, model version and timeout live
in a ConfigMap profile selected by the Deployment. It returns a task label and confidence. Native HTTPRoute rules choose
between two synthetic OpenAI-compatible backends. The backends prove routing;
they do not perform inference. No Part 4 resources or GPU services are referenced.

Local Go unit tests, in-memory gRPC protocol tests with a fake Jev HTTP service,
and the container build have been checked. The real Jev API, Kubernetes deployment,
OSS/Enterprise gateway integration and model quality have not been validated for
this part. The page records that distinction explicitly. There is no tested-version
entry or unattended EKS quick script.

## Requirements

Go 1.24+, Docker, kind, kubectl, Helm, Python 3 and a TypeSafe API key. The Enterprise
variant also needs a Solo licence. Start with a disposable kind cluster; the commands
use a separate kubeconfig. Do not run Parts 1–4's deployment scripts for this guide.

Reference targets, not Part 5 validation claims: Gateway API v1.6.1 experimental,
agentgateway OSS v1.5.0 or Solo Enterprise v2026.9.0, Jev `jev-1.13.0`.

**Data boundary:** every valid prompt reaches TypeSafe's hosted API before a model
backend is selected. Use the committed synthetic examples. A private final model
does not make this a private processing path. The sandbox is unauthenticated and
ClusterIP-only, accessed through a loopback port-forward. Do not publish its listener.

## Build and check locally

From this directory:

```bash
(cd src && go test -race ./... && go vet ./...)
export IMAGE=localhost/jev-routing-kb:part5
docker build -t "$IMAGE" src
docker run --rm -v "$PWD/config:/config:ro" "$IMAGE" \
  -check-profile /config/task-routing.json
```

The tests make no TypeSafe, Kubernetes or cloud calls. They check low confidence,
invalid distributions, missing fields, forged headers, provider failures, timeouts,
unsupported input and a real gRPC stream against an in-memory server.

## Create an isolated sandbox

```bash
mkdir -p .local
kind create cluster --name jev-routing-kb --kubeconfig "$PWD/.local/kubeconfig"
export KUBECONFIG="$PWD/.local/kubeconfig"
export KUBE_CONTEXT=kind-jev-routing-kb
export EDITION=oss                    # or enterprise, on a fresh sandbox
bash scripts/install-controller.sh "$EDITION"
kind load docker-image "$IMAGE" --name jev-routing-kb
kubectl --context "$KUBE_CONTEXT" apply -f yaml/00-namespace.yaml
```

Set `TYPESAFE_API_KEY` in the shell using your secret manager, then:

```bash
python3 scripts/create-secret.py
python3 scripts/render.py --edition "$EDITION" --image "$IMAGE" \
  --profile config/task-routing.json --profile-name jev-task-profile > .local/experiment.yaml
kubectl --context "$KUBE_CONTEXT" apply --dry-run=server -f .local/experiment.yaml
kubectl --context "$KUBE_CONTEXT" apply -f .local/experiment.yaml
kubectl --context "$KUBE_CONTEXT" -n jev-routing-kb rollout status deployment/jev-extproc --timeout=180s
kubectl --context "$KUBE_CONTEXT" -n jev-routing-kb rollout status deployment/coding-fixture --timeout=180s
kubectl --context "$KUBE_CONTEXT" -n jev-routing-kb rollout status deployment/general-fixture --timeout=180s
kubectl --context "$KUBE_CONTEXT" -n jev-routing-kb wait --for=condition=Programmed gateway/jev-kb --timeout=180s
kubectl --context "$KUBE_CONTEXT" -n jev-routing-kb get httproute/jev-routes -o yaml
kubectl --context "$KUBE_CONTEXT" -n jev-routing-kb port-forward --address 127.0.0.1 svc/jev-kb 18085:8080
```

Check HTTPRoute `Accepted` and `ResolvedRefs` and policy status before sending
traffic. The page explains the policy resource names for each edition.

## Test in another terminal

```bash
python3 scripts/test-routing.py > results.json
```

Eight real Jev calls plus four locally rejected requests. The test reports label
agreement, fallback rate, actual Jev model ID, token usage and latency. It asserts
that the observed task reaches the configured fixture, not that Jev always agrees
with the expected label. A classifier error and a gateway routing error are different.

For the outage test, re-export the sandbox kubeconfig and context in this terminal:

```bash
export KUBECONFIG="$PWD/.local/kubeconfig"
export KUBE_CONTEXT=kind-jev-routing-kb
kubectl --context "$KUBE_CONTEXT" -n jev-routing-kb scale deployment/jev-extproc --replicas=0
kubectl --context "$KUBE_CONTEXT" -n jev-routing-kb wait --for=delete pod -l app=jev-extproc --timeout=120s
python3 scripts/test-routing.py --expect-unavailable
kubectl --context "$KUBE_CONTEXT" -n jev-routing-kb scale deployment/jev-extproc --replicas=1
kubectl --context "$KUBE_CONTEXT" -n jev-routing-kb rollout status deployment/jev-extproc --timeout=180s
python3 scripts/test-routing.py
```

Restore the adapter even if the outage assertion fails. To remove the whole
disposable sandbox:

```bash
kind delete cluster --name jev-routing-kb --kubeconfig "$PWD/.local/kubeconfig"
unset KUBECONFIG KUBE_CONTEXT TYPESAFE_API_KEY
```

## Change the questions without rebuilding

`config/task-routing.json` is the source of the first profile. `render.py` emits
an immutable ConfigMap named `jev-task-profile-<content-hash>` and points the
Deployment's `profile` volume at that exact name. The adapter reads
`JEV_PROFILE_PATH=/etc/jev/profile.json` once at startup and fails startup if the
selected Choice question, fallback or thresholds are invalid. Labels are derived
from the selected question's criteria; no task taxonomy is compiled into Go.
If the profile stores several Choice questions, `questionId` selects the single
question sent to Jev and used for routing.

A changed profile creates a new ConfigMap and changes the pod template, causing
a rollout. Existing pods retain their own loaded profile. The response header
`x-jev-profile` identifies the loaded content hash. The API key remains in a Secret.

Pause test traffic while changing the taxonomy: Deployment and HTTPRoute updates
are not atomic. To switch to the included support-triage example, on the same image:

```bash
ROUTES=yaml-oss/31-support-routes.yaml
if [ "$EDITION" = enterprise ]; then ROUTES=yaml/31-support-routes.yaml; fi
docker run --rm -v "$PWD/config:/config:ro" "$IMAGE" \
  -check-profile /config/support-routing.json
python3 scripts/render.py --edition "$EDITION" --image "$IMAGE" \
  --profile config/support-routing.json --profile-name jev-support-profile \
  --routes "$ROUTES" > .local/support.yaml
kubectl --context "$KUBE_CONTEXT" apply --dry-run=server -f .local/support.yaml
kubectl --context "$KUBE_CONTEXT" apply -f .local/support.yaml
kubectl --context "$KUBE_CONTEXT" -n jev-routing-kb rollout status deployment/jev-extproc --timeout=180s
python3 scripts/test-routing.py --profile config/support-routing.json \
  --cases tests/support-cases.json --coding-label technical
```

`technical` goes to the coding fixture; `billing` and `other` go to the general
fixture. `x-jev-task` is a stable wire header even when `questionId` is `department`.
Restore both the original profile and routes by applying `.local/experiment.yaml`
and waiting for the rollout. Old ConfigMaps remain available for rollback until
the namespace is deleted. For several profiles at once, use distinct Deployments,
Services and Gateways and point each ExtProc policy at its own Service; the adapter
does not accept a caller-supplied ConfigMap name.

## Contracts

- One user message with string content, `model: auto`, no tools, no attachments,
  no streaming, up to 32 KiB for the full JSON body. Optional `max_tokens` is 0..1024
  and `temperature` is 0..2. Unsupported shapes are rejected before the paid call.
- The adapter strips its ten owned `x-jev-*` headers before classification and
  overwrites them from a validated response. The prompt body is not changed.
- The default profile requires confidence >= 0.80 and winner margin >= 0.20 to retain its
  label. Otherwise `x-jev-task` becomes `uncertain`. Thresholds are experiment
  defaults, not calibrated acceptance criteria or probabilities of correctness.
- Three coding labels route to `kb-coding`; finance, telco and uncertain use
  `kb-general`. The backend pins the model name. There is no frontier backend.
- The default profile sets a two-second whole-request timeout, with no retries in this inline path.
  API errors and malformed responses produce 503. A stopped adapter is rejected
  by agentgateway's `FailClosed` policy; verify a 5xx rather than a fixed status.
- Logs contain labels, scores, model version, timing and usage, not prompt text
  or credentials. The health probe checks the local listener, not upstream access.

The full guide covers how to compare with vLLM Semantic Router and the additional
data-boundary, identity, client-format and capacity work required before integrating
this classifier with Part 4. Do not replace Part 4's policy with this sandbox route.
