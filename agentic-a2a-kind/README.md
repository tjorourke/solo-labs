# agentic-a2a-kind

Setting up kagent **agent-to-agent (A2A) delegation**: an on-call SRE orchestrator
references a DBA specialist as a tool and hands it a broken-database incident over
the A2A protocol. On the enterprise stack the calling user's identity also rides
the chain as an exchanged On-Behalf-Of (OBO) token, captured live off the wire.

A single, standalone kind cluster running two declarative agents:

- **sre-orchestrator** — the on-call agent. Triages cluster incidents and, when a
  problem looks database-related, delegates to the specialist over A2A by
  referencing it as a tool (`tools[].type: Agent`).
- **dba-agent** — a database specialist. Diagnoses Postgres workload failures and
  advertises its skill on its A2A agent card (`a2aConfig.skills`).

## The story

A Postgres database (`orders/orders-db`) is broken on purpose: no
`POSTGRES_PASSWORD`, so the container refuses to initialise and the pod
crashloops. You ask the SRE orchestrator to triage. It inspects the cluster, sees
a database workload is down, **delegates to the dba-agent**, and the specialist
reads the pod logs, finds the missing password, and returns the exact fix, which
the orchestrator folds into its summary. Because the lab runs on Solo Enterprise
for kagent, the caller's identity flows through as an exchanged OBO token along the
way.

## Bring it up

Standalone cluster. Needs an Anthropic key and two enterprise licenses:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export SOLO_LICENSE_KEY=...             # Solo Enterprise for kagent
export AGENTGATEWAY_LICENSE_KEY=...     # enterprise agentgateway
./scripts/quick.sh up
```

(The Solo charts are pulled from a Google Artifact Registry; `gcloud` must be
installed and authenticated — the scripts run `helm registry login` for you.)

## See the exchange

```bash
./scripts/mint-token.sh alice           # Alice's inbound Keycloak token (no act)
./scripts/ask.sh "the orders database won't start - investigate and fix"   # call as Alice
./scripts/show-obo.sh alice             # inbound token + the /jwks.json signer
                                        #   + the exchanged token, captured live and decoded
```

`ask.sh` calls the orchestrator with Alice's Bearer token; the orchestrator
triages and delegates to the DBA specialist. Try `AS_USER=bob ./scripts/ask.sh ...`
for a different identity (`AS_USER`, not `USER`).

## What `show-obo.sh` captures

The exchanged OBO token rides the controller→agent hop. `show-obo.sh` sniffs that
hop with `ngrep` in an ephemeral container on the orchestrator pod while firing
one call, then decodes the real token: `iss: kagent.kagent`, `sub:` Alice's
preserved Keycloak subject, `act.sub: system:serviceaccount:kagent:sre-orchestrator`,
and a header `kid` that matches `/jwks.json`. If the capture can't run it falls
back to the verified shape, clearly labelled.

## Status

The **OBO token exchange and identity-driven authentication are verified end to
end** (see `CLAUDE.md`). The `AccessPolicy` resources that scope the DBA down are
applied but require kagent's Istio authz-translation layer to enforce, which is
not installed in this single-cluster lab — documented in `CLAUDE.md` with how to
enable it.

## Reset / teardown

```bash
kubectl --context kind-a2a-obo -n orders rollout restart deploy/orders-db  # re-break/reset
./scripts/quick.sh teardown                                                # delete the cluster
```

## Notes

- Needs `docker`, `kind`, `kubectl`, `helm`, `curl`, `gcloud`.
- Fully standalone — its own `a2a-obo` kind cluster, no dependency on any other lab.
- See `CLAUDE.md` for design notes and the end-to-end verification record.
