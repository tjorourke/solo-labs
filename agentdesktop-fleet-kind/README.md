# Agentdesktop fleet mode: central policy and no provider keys on the laptop

Runnable files for the lab at
<https://www.masterthemesh.com/solo/agentdesktop-fleet-kind/>
(also published at <https://mastertheagent.com/solo/agentdesktop-fleet-kind/>).

The Agentdesktop controller on Kubernetes: workstations enrol by certificate
signing request, policy is published centrally as a numbered revision, and
model traffic goes through agentgateway with a five minute controller-minted
JWT instead of an Anthropic key.

## What is here

| Path | What it does |
|---|---|
| `yaml/agentdesktop.sh` | The whole standup: Keycloak `corp` realm and accounts, PostgreSQL, device CA and JWT signing key, the controller by Helm, and the gateway policy. Idempotent, with `teardown`. |
| `yaml/daemon.yaml` | The entire local configuration on a managed workstation. Everything else arrives from the controller. |
| `yaml/gateway.yaml` | The gateway half: strict JWT against the controller JWKS, the Anthropic backend and the `/v1/messages` route. |
| `yaml/workstation/` | Builds a workstation image from the published Linux binary and completes the Keycloak sign-in, for bringing up more than one machine. |

## Prerequisites

This targets an existing cluster. It does not create one.

1. The vision demo platform: Solo Istio in ambient mode, an Enterprise
   agentgateway, Keycloak and MetalLB.
2. The AI gateway standup, which provides the `ai-gateway` Gateway and the
   `anthropic-secret` this lab puts Agentdesktop in front of.
3. `ANTHROPIC_API_KEY`, read once and stored as a Secret in the cluster.
4. The Agentdesktop device binary from the project releases. The assets are
   unsigned, so on macOS run `codesign --force --sign - agentdesktop` or the
   binary is killed on launch.

## Run it

```bash
SECRETS_FILE=~/code/solo/secrets/secrets-envs.sh ./yaml/agentdesktop.sh
```

It prints the controller and Keycloak addresses and the two `/etc/hosts`
entries the workstation needs. The device certificate is issued for the
controller's in-cluster DNS name and the OIDC issuer uses the same form of
name, so both have to resolve to the load balancer addresses.

Console:

```bash
kubectl -n agentdesktop port-forward deploy/agentdesktop 18099:8080
```

Enrol this machine:

```bash
agentdesktop daemon --user --config yaml/daemon.yaml
```

Accounts are `tom`, `priya` and `leaver`, all with the password `password`.

Remove everything with `./yaml/agentdesktop.sh teardown`.

## Three things that will catch you out

- The controller chart defaults `image.tag` to its `appVersion`, and only
  `latest` is published, so the tag has to be pinned or the pod sits in
  `ImagePullBackOff`.
- Keycloak 26 raises a `VERIFY_PROFILE` required action on an account with no
  first name, which interrupts the authorization code flow before a code is
  issued and leaves the daemon on `awaitingAuthentication`.
- `policies.ai.routes` decides whether the gateway answers Anthropic's native
  Messages schema. Without it an AI backend normalises to the OpenAI schema,
  the request still succeeds, and Claude Code cannot read the reply.
