# Provider keys and virtual keys from Vault

Solo Enterprise for agentgateway **v2026.9.0**, Gateway API **v1.5.1**, HashiCorp
Vault chart **0.34.1** (dev mode), Secrets Store CSI Driver **1.6.1**, External
Secrets Operator **2.11.0**, on kind. The virtual-keys half also runs on OSS
agentgateway **v1.5.0** (see [OSS](#oss)).

Two kinds of secret, two different mechanisms:

- **Provider API keys** (the key agentgateway sends upstream to OpenAI and
  friends). Vault projects the key as a file through the Secrets Store CSI Driver.
  An `EnterpriseAgentgatewayExternalSecret` reads that file, and the backend's
  `policies.auth.secretRef` points at it. The key never becomes a Kubernetes
  Secret. Enterprise only.
- **Virtual keys** (the keys your clients send to the gateway). External Secrets
  Operator syncs the SHA-256 hashes and metadata from Vault into a Kubernetes
  Secret, and `apiKeyAuthentication.secretRef` reads it. The Secret holds hashes,
  never the raw client keys. Works on OSS and Enterprise.

Note that the two have different security postures. `kubectl get secrets` never
shows the provider key. It does show `virtual-key-hashes`, by design.

All LLM traffic goes to a local mock that echoes the `Authorization` header it
received, so you can see exactly which key the gateway sent. No provider key or
real spend is needed.

## Run

Prerequisites: Docker running, kind, kubectl, Helm, Python 3 and an exported
`AGENTGATEWAY_LICENSE_KEY`. Alternatively set `SECRETS_FILE` to a local shell
environment file (default `~/code/solo/secrets/secrets-envs.sh`).

Run from this directory:

```bash
bash scripts/quick.sh up
bash scripts/quick.sh test
bash scripts/quick.sh rotate
```

`up` creates the kind cluster, installs Vault in dev mode, the CSI driver (with
secret rotation on), ESO and agentgateway, then seeds
Vault and configures two Kubernetes auth roles:

| Vault role | Bound ServiceAccount | Can read |
|---|---|---|
| `agentgateway` | `enterprise-agentgateway` (the controller) | `secret/data/openai-api-key` |
| `eso-virtual-keys` | `eso-virtual-keys-reader` | `secret/data/virtual-keys/*` |

`test` runs these checks against the live cluster:

1. The provider key appears in no Kubernetes Secret.
2. The mock receives `Bearer <key>` with the value from Vault.
3. After `vault kv put` with a new key, the mock receives the new value, and no
   gateway pod restarts.
4. All four virtual keys return 200 and a request without a key returns 401.
5. Replacing Alice's hash in Vault turns her requests into 401 once ESO syncs,
   while Carol keeps working. No gateway pod restarts.
6. Each Vault role is denied the other role's path.

It resets Vault to the seeded state first, so you can run it again.

`rotate` writes a new provider key to Vault and prints what the mock receives
once a second until it changes. Across five runs on the validation cluster it took
between 22 and 88 seconds, with no gateway restart in any of them. See
[How long changes take](#how-long-changes-take) for why it varies.
Pass your own value with `python3 scripts/rotate.py sk-my-new-key`.

## Manual requests

```bash
# Separate terminal
bash scripts/quick.sh forward

# Provider key flow: no client credential, the gateway adds the Vault key
curl -s http://localhost:18080/v1/openai \
  -H 'Content-Type: application/json' \
  -d '{"model":"any","messages":[{"role":"user","content":"hello"}]}' | python3 -m json.tool

# Virtual key flow
curl -i http://localhost:18080/v1/chat/completions \
  -H 'Authorization: Bearer vk-demo-alice-not-for-production' \
  -H 'Content-Type: application/json' \
  -d '{"model":"any","messages":[{"role":"user","content":"hello"}]}'
```

Look at `received_authorization` in the first response. Keys follow the public
pattern `vk-demo-<user>-not-for-production` for alice, bob, carol and dave. Use
random credentials in real deployments. `PORT=18081 bash scripts/quick.sh forward`
picks another local port.

Read and change the secrets in Vault directly:

```bash
kubectl --context kind-agw-vault-secrets -n vault exec vault-0 -- vault kv get secret/openai-api-key
kubectl --context kind-agw-vault-secrets -n vault exec vault-0 -- vault kv get secret/virtual-keys/alice
```

## Configuration

- `yaml/secret-provider-class.yaml`: the Vault objects the CSI driver projects.
  Applied before the controller install, because the pod cannot start while its
  CSI volume names a missing SecretProviderClass.
- `yaml/csi-store-values.yaml`: Helm values that mount the CSI volume on the
  controller and register it as the `llm-secrets` file store. The store `path` and
  the mount path must match and sit under `/var/run/secrets/agentgateway-external-secrets`.
- `yaml/external-secret.yaml`: `EnterpriseAgentgatewayExternalSecret` reading the
  `openai-api-key` file into the `Authorization` key.
- `yaml/backend-openai.yaml`: the backend whose `policies.auth.secretRef` points
  at the external secret.
- `yaml/eso-secretstore.yaml`: ESO's SecretStore, using the `eso-virtual-keys` role.
- `yaml/eso-external-secret.yaml`: syncs the four users into `virtual-key-hashes`
  every minute.
- `yaml/virtual-keys-policy.yaml`: `apiKeyAuthentication` on the `llm` route.
- `yaml/gateway.yaml`: the Gateway, both routes and the plain mock backend.
- `yaml/mock.yaml`: the local LLM fixture.
- `yaml/ui-values.yaml` and `yaml/telemetry.yaml`: optional Solo UI.
- `scripts/seed-virtual-keys.py`: writes the virtual-key hashes into Vault.

### How long changes take

- Provider key: the kubelet decides. Since CSI driver v1.6.0 the driver's
  CSIDriver object sets `requiresRepublish: true`, so the kubelet re-publishes the
  volume on its own periodic pod sync, and the driver re-fetches from Vault on
  that call. `rotationPollInterval` (15s here) is only the minimum gap between
  two fetches. The driver logs showed republishes 65 to 89 seconds apart, so plan
  for up to about a minute and a half. The `refreshInterval` on the external
  secret is a fallback; agentgateway picks up the file change straight away.
- Virtual keys: the ExternalSecret's `refreshInterval` (1m here), then the policy
  reloads from the updated Secret.

Every kubectl and Helm call uses the explicit context `kind-agw-vault-secrets`.
`CLUSTER`, `AGW_VERSION`, `GWAPI_VERSION`, `VAULT_CHART_VERSION`,
`CSI_DRIVER_VERSION`, `ESO_VERSION` and `MGMT_VERSION` are optional overrides,
and have not passed the recorded validation unless they match it.

## Optional UI

```bash
bash scripts/quick.sh ui
bash scripts/quick.sh ui-forward
```

Open **http://localhost:18090/age/**. The UI's bundled ClickHouse needs about
3 GiB of extra Docker memory.

## OSS

`yaml-oss/` holds the virtual-keys flow only, converted to `AgentgatewayPolicy`,
`AgentgatewayBackend` and `gatewayClassName: agentgateway`. The provider-key flow
has no OSS equivalent, so it is not there.

```bash
EDITION=oss bash scripts/quick.sh up
EDITION=oss bash scripts/quick.sh test
EDITION=oss bash scripts/quick.sh teardown
```

The OSS run uses its own cluster, `agw-vault-secrets-oss`, skips the CSI driver
and needs no licence key.

## Cleanup

Stop port-forwards with Ctrl-C, then `bash scripts/quick.sh teardown`. It deletes
only the lab's kind cluster and checks it is gone. Vault runs in dev mode, so
everything in it goes with the cluster. Full walkthrough: [index.html](index.html).
