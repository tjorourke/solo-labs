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
make show      # the six lines that wire ADK to the gateway
make build     # multi-stage docker build (maven -> jre)
make push      # into the kind registry
make publish   # register it in AgentRegistry with arctl
make run       # run it in the cluster as a Job and print the output
make all       # all of the above
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

## Two honest limitations

**It holds no GitHub credential, and it also holds no A2A server.** AgentRegistry will
publish this agent and `arctl apply` a Deployment for it, but the kagent readiness probe
is `http-get /.well-known/agent-card.json`, so a batch program will never come up Ready.
Running it as a Job is the honest shape. Making it a deployed kagent agent means
implementing A2A plus the controller callback in Java, which is a project rather than a
demo beat.

**`arctl init` cannot scaffold this.** As of `v2026.6.1` it scaffolds ADK with Python
only: `--language java`, `go` and `typescript` are all rejected with "no agent framework".
The catalogue itself is language-agnostic, since an Agent record just references an
image, which is why `make publish` works.

## The one local tool

`today()`. The gateway's code sandbox deliberately has no clock, so a program in there
cannot work out the date. Without this tool the model invents one, and on the first run
it invented January.
