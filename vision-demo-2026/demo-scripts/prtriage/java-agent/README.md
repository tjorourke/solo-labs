# The Java agent

The same release report, in Java, on the same Google ADK, through the same
agentgateway endpoint as the Python agent in Part 8. It exists because Devoxx is a
Java conference and "your agent can be Java" is worth showing rather than asserting.

Nothing about the gateway, the catalogue or the policy changes. That is the argument:
the tool layer is not the agent's problem, and it is not the agent language's problem.

## No JDK needed

Maven and the JDK run inside the image. The machine driving the demo needs Docker and
nothing else.

```bash
make show      # the method that wires ADK to the gateway
make build     # multi-stage docker build (maven -> jre)
make push      # into the kind registry
make publish   # register it in AgentRegistry with arctl
make deploy    # deploy onto kagent as a pod, the same shape as the Python agent
make ask       # prompt it through kagent's OIDC-protected A2A endpoint
make run       # run it as a one-shot Job instead, which is what the notebook uses
make all       # build, push, publish, deploy, ask
make clean
```

## What it proves, and it is the same beat in both languages

With the gateway in `Standard` mode:

```
tools the gateway handed this Java agent: 45
model tool calls: 18
```

Flip one field to `CodeSearch` and run it again:

```
tools the gateway handed this Java agent: 2
    - get_tool
    - run_code
model tool calls: 2
```

Same twenty four pull requests, same verdicts, same correct count. The agent did not
change, was not rebuilt, and does not know which mode it is in.

## The files, and why each one is there

| file | why |
|---|---|
| `src/.../ReleaseReport.java` | the wiring, and the whole point is how little is in it |
| `src/.../Config.java` | everything the agent is told, and note there is no GitHub credential in it |
| `src/.../OneShot.java` | ask once, print what it cost, exit. The shape `make run` uses |
| `src/.../A2aServer.java` | the two endpoints kagent needs from a long-lived agent |
| `src/.../Turn.java` | one question through an ADK runner |
| `src/.../Console.java` | the demo's output, kept out of the agent code |
| `src/.../Json.java` | Jackson comes in with ADK, so no JSON is parsed by hand |
| `pom.xml` | one dependency, `google-adk`. MCP and Claude both come with it |
| `Dockerfile` | multi-stage, so no JDK is needed on the machine |
| `Makefile` | show, build, push, publish, run |
| `agent.yaml` | the AgentRegistry catalogue entry |
| `skill.md` | **generated** by the Makefile from the approved skill. Not under source control, because a second editable copy would drift |

## Verified API, not remembered API

Everything here was checked against `com.google.adk:google-adk:1.9.0` by reading the
jar rather than trusting a memory of the API:

- `com.google.adk.tools.mcp.StreamableHttpServerParameters`, which is the transport the
  gateway serves. There is a direct `McpToolset(StreamableHttpServerParameters)`
  constructor.
- `com.google.adk.models.Claude(String, AnthropicClient)`, on
  `com.anthropic:anthropic-java`, which ADK brings in itself.
- `FunctionTool.create(Class, String)` for the one local tool.

The build compiled first time as a result.

## It runs as a proper kagent agent

`SERVE=true` starts the A2A server in `A2aServer.java`, so this is a long-lived pod
serving `/.well-known/agent-card.json`, exactly like the Python agent. Verified:

```
$ kubectl -n kagent get agent prtriage prtriagejava
NAME           TYPE   RUNTIME   READY   ACCEPTED
prtriage       BYO              True    True
prtriagejava   BYO              True    True
```

Both prompted the same way through the controller, both returning the same report.

Two things learned getting there, and neither is documented anywhere obvious:

**A2A `message/send` must return a `Message` or a `Task`, discriminated by a `kind`
field.** Return artifacts without it and kagent's controller rejects a perfectly good
answer with `failed to unmarshal rpc result: unsupported result kind`. The agent had
already done the work and produced the right text. That is a confusing half hour if you
have not read the spec, so `A2aServer.task()` builds a full Task with `kind`, `id`,
`contextId`, a completed `status` and the artifact.

**There is no A2A SDK for Java on Maven Central**, at least under any of the obvious
coordinates. The contract is small enough not to need one: two endpoints, and the whole
server is under two hundred lines with no dependency beyond the Jackson that ADK
already brings.

`ask.sh` needed one change to reach a non-Python agent. It mints the OIDC token by
`kubectl exec`-ing into the target pod and running `python3`, which a Java image does
not have, so `EXEC_FROM=prtriage` points the exec at a pod that does while the A2A URL
still targets the Java agent.

**`arctl init` cannot scaffold this.** As of `v2026.6.1` it scaffolds ADK with Python
only: `--language java`, `go` and `typescript` are all rejected with "no agent framework".
The catalogue itself is language-agnostic, since an Agent record just references an
image, which is why `make publish` works.

## The one local tool

`today()`. The gateway's code sandbox deliberately has no clock, so a program in there
cannot work out the date. Without this tool the model invents one, and on the first run
it invented January.
