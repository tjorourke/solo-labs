# Part 8 talk track

The story, the beats and the numbers for driving `demo-8-github-agent.ipynb` in front
of a room. The notebook is the machinery; this is what you say while it runs.

Every number here was measured on `mesh1` against `tjorourke/kagent` with
`claude-haiku-4-5` and Solo Enterprise for agentgateway `v2026.8.2`. Nothing is
estimated.

## The story in one sentence

A developer wires GitHub's MCP server to an agent, it works, and three things are now
true that nobody chose: the agent is carrying 44 tool definitions on every turn, 17 of
those tools can write to the repository, and the model is being handed tens of
thousands of bytes of raw API responses to remember. All three get fixed one layer
down, and none of the fixes are in the agent's code.

## The argument, in three moves

1. **Connecting one MCP server is not free.** 44 tools, 14,572 tokens per turn, and 17
   write operations the agent now has, including `delete_file` and
   `merge_pull_request`. No token scope can say "this one agent may only read pull
   requests", because a scope is coarse and the token is shared by everyone using it.
2. **The cost is not only tokens, it is correctness.** Gathering data one call at a
   time puts every raw response in the context window. Measured against the live
   upstream repo, the default mode twice reported pull requests as ready to merge that
   had no approval at all, and once dropped a pull request and reported seven of eight.
3. **Both are fixed at the gateway, and one field does it.** Flip `toolMode` and the
   model writes one program instead of taking twenty turns. The filtering happens in a
   sandbox, on data the model never has to hold.

Then the governance close: take the write tools away per agent, and watch the denied
operation stop existing.

## The six beats

Roughly twelve minutes. Timings assume you are talking over the cells, not waiting in
silence.

### Beat 1 · What one MCP server costs you (1 min)

**On screen:** the `tools/list` count, the byte count, the list of 17 write tools, then
the token count from Anthropic's own counter.

**Say:** this is one server. Forty four tools, and fourteen and a half thousand tokens
of tool schema in the context before anyone has typed anything. Then read three write
tool names off the screen slowly: `delete_file`, `push_files`, `merge_pull_request`.

**The line that lands:** your agent can merge a pull request, and nothing in your agent
framework has an opinion about that.

### Beat 2 · The gateway holds the credential (1 min)

**On screen:** the `EnterpriseAgentgatewayBackend`, with two fields highlighted:
`protocol: StreamableHTTP` and `policies.auth.secretRef`. Then a live MCP call that
carries no `Authorization` header and returns real pull requests.

**Say:** the token lives in one Secret that the gateway reads. The agent gets a plain
URL with no credential in it.

**The line that lands:** the agent cannot leak a token it was never given.

Worth pausing here if the room is security-minded. This is the beat that makes people
lean forward.

### Beat 3 · Scaffold from the approved catalogue (3 min)

**On screen:** `arctl get mcpserver github-mcp`, pointing at the URL. Then
`scaffold-agent.sh`, which shows the scaffold's own sample tools and then the swap.

**Say two things, in this order.**

First, the catalogue entry resolves to the **gateway route**, not to
`api.githubcopilot.com`. A developer who picks GitHub out of the catalogue gets GitHub
through the enforcement point, and there is no catalogue entry that means "GitHub, but
skip the gateway".

Second, the approved **skill**. Open it and read a couple of lines out. The parameter is
`pullNumber` and not `pull_number`. The sandbox has no `Date`. Labels arrive as strings
or as objects. Every one of those lines is in there because a run failed without it.

**The line that lands:** the platform team pays for that once, and every agent gets it.

### Beat 4 · Deploy with AgentRegistry and run it (3 min)

**On screen:** the four-line `Deployment` record, then the pod coming up, then the
kagent UI. Prompt it in the UI, not the terminal, and open the Tracing tab.

**Say:** one record naming an agent and a runtime. AgentRegistry creates the kagent
`Agent`, derives the MCP wiring from the catalogue, and the controller brings it up.
No Helm, no hand-written pod spec.

Then run the question and **read the trace, not the answer**. Ten round trips, each one
re-sending the whole conversation, and 34,288 bytes of raw GitHub JSON crossing the
context window to produce nine lines of report.

**Do not skip this:** ten is already better than it could be, and the skill is why. It
tells the agent to project fields on the list call and make one call per pull request
instead of three. Without that guidance the same job took twenty round trips and 87,630
bytes. The registry earns half the saving before the gateway does anything.

### Beat 5 · One field (2 min)

**On screen:** the `toolMode` patch, `tools/list` dropping from 44 to 2, then the same
question again. Put the two traces side by side if you can.

**Say:** same agent, same image, same catalogue. One field on the backend. The model
now gets `get_tool` to look up a schema and `run_code` to execute a program against
them. Two round trips: the date, then one program that made nine GitHub calls inside
the gateway and returned the finished report.

**What to actually show:** scroll the Standard trace so the room sees a screenful of
raw JSON, then show the CodeSearch trace, which is two lines. That contrast reads from
the back row. The byte counts underneath turn it into a number: 34,288 against 11.

**Do not promise it is faster.** At this size both runs take about twenty seconds, and
somebody will time you. What changed is what the model has to carry, not the clock.

Then the sandbox probe, which is worth thirty seconds on its own: no `fetch`, no
`require`, no `process`. The only way out of that sandbox is the generated tool
functions, so a program cannot phone home. It can only call approved tools.

### Beat 6 · Take the write tools away (2 min)

**On screen:** the `EnterpriseAgentgatewayPolicy`, then a program that tries the denied
operation, then the agent itself refusing.

**Say:** the report needs to read pull requests. The agent has been holding forty five
tools all along, seventeen of which write. This policy names what it actually needs, on
the MCP method name, per agent.

The denial is the best thirty seconds in the demo, so land it properly. In Standard
mode a denied tool is filtered out of the listing and a direct call comes back as
`Unknown tool`, not `403`, so nothing leaks. In code mode it is stronger: the generated
API is built **after** the policy is applied, so the denied operation is not a function
in the sandbox at all. The program cannot express the call.

Then ask the agent to merge a pull request and let it say it cannot.

**The closing line:** the token in that Secret still has every permission it always had.
The gateway is what makes this agent read-only, and it does it per agent, which no
token scope can.

## The numbers

| | Standard | CodeSearch |
|---|---|---|
| tools the model holds | 45 | 2 |
| schema tokens per turn | 14,572 | 1,300 |
| model round trips | 10 | 2 |
| payload through the model | 34,288 B | 11 B |
| wall clock | 17-21 s | 17-22 s |

Against the live upstream repo, where responses are the size they are in real life:

| | Standard | CodeSearch |
|---|---|---|
| model round trips | 20 | 2 |
| payload through the model | 87,630 B | 11 B |
| got the answer right | no, twice | yes |

All four `toolMode` settings, if someone asks:

| `toolMode` | tools | schema tokens | round trips | what it fixes |
|---|---|---|---|---|
| `Standard` | 45 | 14,572 | 20 | nothing, it is the default |
| `Search` | 3 | 986 | 22 | what the model has to hold |
| `Code` | 2 | 6,302 | 2 | what the model has to do |
| `CodeSearch` | 3 | 1,300 | 2 | both |

`Search` and `Code` are two independent choices, which is why there are four settings
and not three:

| | schemas fetched on demand | all schemas up front |
|---|---|---|
| one operation per call | `Search` | `Standard` |
| one program, many operations | `CodeSearch` | `Code` |

## Questions you will get

**"Is this just prompt engineering?"** No. The tool list the model receives is
constructed by the gateway, and so is the generated API inside code mode. The agent's
image and prompt are unchanged across every beat in the demo.

**"Could I not just filter the tools in my agent code?"** You could filter what you
pass to the model. You cannot stop the agent calling a tool it decides to call, because
that decision and that call both happen after your code has run. The denial in beat 6
is enforced on the wire, on the agent's own identity.

**"What is the sandbox?"** A restricted JavaScript runtime with no network access of
its own. `Math`, `JSON`, `Promise`, `Object`, `Array`, `String`, `Number`, `RegExp` and
`BigInt` are present. `Date`, `fetch`, `Map`, `Set`, `console`, `process`, `require`
and `setTimeout` are not.

**"What are the limits?"** A program may make at most 20 upstream tool calls, and
exceeding it discards the whole program. That is what sizes the demo at eight pull
requests.

**"Is any of this open source?"** kagent and agentregistry are CNCF sandbox projects,
agentgateway is in the Linux Foundation. The `toolMode` settings shown here are an
Enterprise field on `EnterpriseAgentgatewayBackend`; OSS filters which tools a backend
exposes, which keeps the list short by a different route.

**"Why is the report about a fork?"** Because the demo data has to be frozen. See
below.

## Why the data is frozen, and say so if asked

The pull requests are seeded fixtures in a fork, built by
`demo-scripts/prtriage/scripts/seed-demo-repo.sh`. Reading live pull requests from a
busy repository is a bad bet on a projector: the answer changes hour to hour, the
numbers stop matching the slides, and the model sometimes over-fetches and trips the
20-call cap. Because the fork has exactly eight open pull requests, the question is
"all open pull requests" and over-fetching stops being possible.

The gate is a draft flag, the `do-not-merge/hold` label and a comment starting with
`LGTM`. Three things a token can genuinely produce. Approvals are out because GitHub
will not let you approve your own pull request, check runs and commit statuses are out
because a fine-grained token cannot write either, and `mergeable` was tried and dropped
because GitHub computes it lazily and returns `null` often enough to misreport a real
conflict.

One pull request says "lgtm" in the middle of a sentence while explicitly declining to
sign off. The rule is `LGTM` at the start of a comment. It has been read correctly on
every verification run, and it is a good thing to point at if someone asks whether the
agent is really reading the data.

## Before you walk on

1. `source demo-scripts/env.sh 8`, then run the Connect cell and check the MCP endpoint
   answers.
2. Run beat 1 once to warm everything, then reset `toolMode` to `Standard` and delete
   any policy left behind. The last cell in the notebook does both.
3. Pre-capture the `tools/list` output to a file. It is your only real external
   dependency besides the model API, and a screenshot beats an apology.
4. Do beat 1 early while the room's wifi is least contended. Never put a network call
   in the closing beat, which is why beat 6 is local.
5. Do not press Sync fork on the demo repository. It moves `main` and can hand a
   fixture branch an unplanned conflict.

## If something breaks

**The agent answers with `Failed to create MCP session`.** DNS. The suite's endpoints
are `*.<lb-ip>.sslip.io`, and resolvers with rebinding protection refuse to return a
private address. Run `demo-scripts/prtriage/scripts/fix-cluster-dns.sh`, which gives
CoreDNS a hosts block for the suite's names.

**A `toolMode` change appears to do nothing.** The agent lists its MCP tools once at
startup. `demo-scripts/prtriage/scripts/reload-agent.sh` restarts it and waits for
exactly one running pod.

**A prompt fails with `cannot exec in a deleted state`.** Same script. It happens when
a call lands on a pod that is still terminating.

**A rebuilt agent behaves as though nothing changed.** The image is `:latest` and
kagent runs it `IfNotPresent`, so a push on the same tag can reuse the node's cached
copy. `rebuild-agent.sh` drops the cached image and then asserts the running pod really
has the current skill.

## What not to claim

1. Do not say it is faster. At this size it is not, and the room can see a clock.
2. Do not stage the accuracy failure as a live beat. It is real and it is measured, but
   it is stochastic, and on these small fixtures the model copes. Show it as evidence
   and demonstrate the fix.
3. Do not say OSS cannot shape tool lists. It can filter which tools a backend exposes.
   What is Enterprise is replacing the list with meta tools.
