# agentic-structured-output-kind

One JSON contract, shared across an A2A call, enforced two different ways.

An on-call **SRE orchestrator** investigates a broken database, then delegates
the diagnosis to a **DBA specialist** over the A2A protocol. The specialist
answers in a strict shape, the `Diagnosis` contract:

```json
{ "root_cause": "string", "severity": "low|medium|high|critical", "fix": "string", "runbook_url": "string" }
```

There are two DBA specialists. They return the **same** contract, but they
enforce it in two different ways:

- **dba-agent-declarative** — a declarative kagent Agent forced to answer only by
  calling an MCP tool, `record_diagnosis`, whose input schema **is** the contract.
  No prose is possible; the tool call is the answer.
- **dba-agent-byo** — a BYO Google ADK agent whose pydantic `output_schema` **is**
  the contract. ADK holds the model to the shape in code.

Because both return the same shape, the orchestrator consumes them
interchangeably: swapping the specialist does not change what the caller reads.

## Do I need agentgateway for this?

No. The shape is enforced **at the agent** (the MCP tool schema, or the ADK
output schema), and kagent speaks A2A natively, so the typed result rides the
hop on its own. Agentgateway is the optional front door — one entry point for
A2A and MCP, edge auth and token exchange, guardrails, observability. It governs
*who calls and what crosses*, not the *shape*. This lab is kagent-only and runs
on OSS.

## Bring it up

Standalone single kind cluster. The only secret is an Anthropic key.

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./scripts/quick.sh up
```

`quick.sh up` creates the cluster, installs OSS kagent (Anthropic + the bundled
Kubernetes tool server), builds and loads the two lab images, then applies the
agents and the broken Postgres.

## See the contract

```bash
./scripts/contract.sh declarative   # DBA via the record_diagnosis MCP tool schema
./scripts/contract.sh byo           # DBA via the ADK pydantic output_schema
```

Each calls a DBA directly over A2A with a fixed piece of incident evidence and
prints exactly what comes back, including any structured data part.

End to end — the orchestrator investigates the cluster, gathers the evidence,
delegates, and folds the verdict into its summary:

```bash
./scripts/ask.sh "the orders database won't start - investigate and fix"
./scripts/ask.sh "... and use the ADK DBA"     # steer which specialist
```

## The incident

`orders/orders-db` is a Postgres Deployment with **no `POSTGRES_PASSWORD`** and
no trust auth, so the entrypoint refuses to initialise and the pod crashloops:

```
Database is uninitialized and superuser password is not specified.
```

Diagnosable entirely from the pod logs.

## Reset / teardown

```bash
kubectl --context kind-agent-contract -n orders rollout restart deploy/orders-db  # re-break/reset
./scripts/quick.sh teardown                                                        # delete the cluster
```

## Notes

- Needs `docker`, `kind`, `kubectl`, `helm`, `curl`, `python3`.
- Fully standalone — its own `agent-contract` kind cluster, no dependency on any
  other lab. Related: `agentic-a2a-kind` covers A2A delegation + the OBO identity
  hop; this lab is about the shape that crosses.
- See `CLAUDE.md` for design notes and the end-to-end verification record.
- The OSS API here (kagent OSS) is the same one Solo Enterprise for kagent ships;
  the enterprise front door (agentgateway auth + AccessPolicy + observability)
  sits on top without changing the contract.
