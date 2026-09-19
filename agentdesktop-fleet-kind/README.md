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
| `yaml/enrol-mac.sh` | Downloads and signs the device binary, prints the `/etc/hosts` lines, previews the change, enrols, and shows what landed in Claude Code. |
| `yaml/cost-retention.sh` | Puts a retention window on the Cost Management rollups so a long-lived cluster does not climb in CPU with age. |
| `yaml/workstation/` | Builds a workstation image from the published Linux binary and completes the Keycloak sign-in, for bringing up more than one machine. |

## Prerequisites

This targets an existing cluster. It does not create one.

1. The vision demo platform: Solo Istio in ambient mode, an Enterprise
   agentgateway, Keycloak and MetalLB.
2. The AI gateway standup, which provides the `ai-gateway` Gateway and the
   `anthropic-secret` this lab puts Agentdesktop in front of.
3. `ANTHROPIC_API_KEY`, read once and stored as a Secret in the cluster.
4. The Agentdesktop device binary. `./yaml/enrol-mac.sh binary` downloads the
   release asset for your platform, checks the digest and adds the ad-hoc
   signature macOS needs before it will run an unsigned binary.

## Run it

```bash
./yaml/agentdesktop.sh
```

No secrets are needed here. The Anthropic key was already stored in the cluster
by the AI gateway standup, and the controller chart is fetched from the project
repository unless `AGENTDESKTOP_CHART` points at a checkout you already have.

It prints the controller and Keycloak addresses and the two `/etc/hosts`
entries the workstation needs. The device certificate is issued for the
controller's in-cluster DNS name and the OIDC issuer uses the same form of
name, so both have to resolve to the load balancer addresses.

Console:

```bash
kubectl -n agentdesktop port-forward deploy/agentdesktop 18099:8080
```

Enrol this machine. Preview first: the daemon reconciles into Claude Code's
real `settings.json`, which affects every Claude Code session on the machine.
`AD_SAFE=1` sends the managed file to `/tmp` instead.

```bash
./yaml/enrol-mac.sh binary
./yaml/enrol-mac.sh hosts      # add the two lines with sudo
./yaml/enrol-mac.sh preview
./yaml/enrol-mac.sh up         # browser opens, sign in tom / password
./yaml/enrol-mac.sh check
```

Accounts are `tom`, `priya` and `leaver`, all with the password `password`.

## Sharing a laptop with another gateway demo

Claude Code has one base URL and one credential helper, so two demos that route
it through a gateway will overwrite each other. `enrol-mac.sh` refuses to start
while another one owns those keys, and snapshots the real default before the
daemon writes anything.

```bash
./yaml/enrol-mac.sh state    # which demo owns Claude right now
./yaml/enrol-mac.sh down     # unenrol and put Claude back
```

`down` stops the daemon, restores Claude Code, clears the local device identity
and removes the device from the controller. The restore runs before any remote
work, so an unreachable cluster still leaves the laptop back to normal. Restart
Claude Code and Claude Desktop afterwards.

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
