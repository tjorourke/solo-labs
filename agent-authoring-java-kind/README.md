# agent-authoring-java-kind

Part 5 of *Writing agents for kagent*. Build the SRE triage agent with Google ADK for
Java and implement its kagent integration. The tested release has no Java runtime,
so the example includes an A2A server and controller task/session writes.

[Browse the files in solo-labs](https://github.com/tjorourke/solo-labs/tree/main/agent-authoring-java-kind).
Clone `https://github.com/tjorourke/solo-labs.git` and run commands from
`agent-authoring-java-kind/`. Keep `agent-authoring-contract-kind/` alongside it.

The agent answers one question, the same one every part of the series answers:
"which pods in this namespace are unhealthy, and why?" It reads pods, descriptions,
logs and events through the `sre-tools` agentgateway waypoint from Part 1, applies the
health gate with a local tool, and returns a short report.

Read Part 1 before this lab. The Python and Go implementations are alternatives,
not prerequisites for Java.

## Supported behaviour and limits

- The server handles `message/send` and `message/stream`, plus the agent card.
  A2A task retrieval, cancellation and stream resubscription are not implemented.
- Each question gets a new `InMemoryRunner` and ADK session. Previous kagent tasks
  are not loaded into the next model turn. A conversation can be visible in the UI
  without the model remembering its earlier messages.
- Tool activity streams as it happens; the final answer text is sent after the
  turn completes, not token by token.
- The streaming path posts the task and session events to the controller.
  `message/send` returns a Task without performing those writes.
- Caught runtime exceptions become answer text with a `completed` task status.
  Controller-write failures are logged without a durable retry queue. Finishing
  the stream does not prove that execution or persistence succeeded.

## Prerequisites

An existing cluster with:

- Solo Enterprise for kagent (the controller, the UI, OIDC)
- Solo Enterprise for agentgateway, and an ambient mesh with the `kagent` namespace enrolled
- a `default-model-config` ModelConfig and the `kagent-anthropic` Secret in `kagent`
- Part 1's shared pieces (`../agent-authoring-contract-kind/scripts/platform.sh up`);
  `quick.sh up` runs it for you
- Docker, and a registry the cluster pulls from at `localhost:5001` (the kind registry)

No JDK or Maven on the machine: both run inside the Docker build.

## Run it

```bash
export CTX=kind-mesh1                 # the kubectl context of that cluster
./scripts/quick.sh up                 # platform pieces, build + push, deploy sre-java
../agent-authoring-contract-kind/scripts/ask.sh sre-java "Which pods in sre-lab are unhealthy, and why?"
./scripts/quick.sh test               # the four checks
./scripts/quick.sh teardown           # removes sre-java only
```

`ask.sh` opens a kagent session and streams the turn through the controller, so the same
conversation is in the kagent UI under the agent.

## The code

`src/` is a Maven project shaded into one jar.

| file | job |
|---|---|
| `SreTriage.java` | the agent: model, instruction, MCP toolset, one local tool |
| `A2aServer.java` | the agent card, JSON-RPC `message/send` and `message/stream` |
| `KagentSession.java` | `POST /api/tasks` and the session events, with the projected token |
| `Progress.java` | tool calls reported as the model makes them, so the stream shows them |
| `Turn.java` | one question through an ADK runner |
| `Config.java` | every environment variable, in one record |
| `Console.java` | the agent's log lines |
| `Json.java` | Jackson helpers |
| `Telemetry.java` | OpenTelemetry autoconfigure, so ADK's spans reach the collector |
| `src/main/resources/instruction.txt` | the system prompt |

## Notes

- The image tag is fixed (`localhost:5001/sre-java:lab`) and the Agent pulls with
  `imagePullPolicy: Always`; `build.sh` restarts the Deployment after a push.
- `quick.sh teardown` leaves the shared pieces in place; Part 1's teardown removes them.
