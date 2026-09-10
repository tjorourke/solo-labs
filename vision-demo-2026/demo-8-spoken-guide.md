# Part 8 · spoken guide

What to say, in order, while `demo-8-github-agent.ipynb` runs. Roughly twelve minutes.

The sentences in the **Say** blocks are meant to be said close to as written. Everything
else is a cue. Numbers are measured on `mesh1` against `tjorourke/kagent`, twenty four
seeded pull requests, `claude-haiku-4-5`, agentgateway `v2026.8.2`. The agent is **Java on Google ADK**.

The two claims that hold on every single run, and the only two to build on:

1. Nineteen tool calls become two.
2. Around 80,000 bytes through the model become a couple of dozen.

Do not claim it is faster. Both land around thirty seconds and somebody will time you.

---

## Before you start

1. `source demo-scripts/env.sh 8`, run the Connect cell, check the MCP endpoint prints.
2. Run beat 1 once to warm the path, then reset: the last cell puts `toolMode` back to
   `Standard` and deletes any policy.
3. Confirm the repo still has twenty four open pull requests, four held, three drafts.
4. Have the `tools/list` output captured to a file as a fallback.
5. Windows you want open: the notebook, the kagent UI, and a terminal. You do not need
   the GitHub UI, and there is a reason to avoid it in beat 1.

---

## Beat 1 · What one MCP server costs you

**Run:** the `tools/list` cell, then the token count cell.

**Say:**

> I wanted an agent that could tell me which pull requests were ready to merge. So I
> connected GitHub's MCP server, which is one server, and this is what turned up.
>
> Forty four tools. A hundred and twenty four kilobytes of tool definitions. Fourteen
> and a half thousand tokens, and that is in the context on every single turn, before
> anyone has typed a question.
>
> Now look at the second list. Seventeen of those forty four can write.
> `create_or_update_file`. `push_files`. `delete_file`. `merge_pull_request`.
>
> I did not choose any of that. I connected one server. And there is nothing in my
> agent framework that has an opinion about it.

**Cue:** read the three write tool names slowly. That is the moment the room goes quiet.

**If asked "can't you just not pass those tools to the model?":** you can filter what
you pass, but you cannot stop the agent calling a tool it decides to call, because that
happens after your code has run. Hold that thought, we come back to it at the end.

---

## Beat 2 · The gateway holds the credential

**Run:** the backend YAML cell, then the no-credential call.

**Say:**

> Before we build anything, one piece of plumbing. That is agentgateway in front of
> GitHub's MCP server. Two fields matter. `protocol: StreamableHTTP`, because GitHub's
> server is hosted and speaks that. And `policies.auth.secretRef`, which is where the
> token lives.
>
> The token is in one Kubernetes Secret that the gateway reads. Watch this call. Content
> type, accept, and nothing else. No authorization header at all.
>
> And there is real GitHub data coming back.
>
> The agent I am about to build has no GitHub credential. Not a scoped one, not a
> short-lived one. None. It cannot leak a token it was never given.

**Cue:** point at the curl line and say "no authorization header" out loud. People skim
past it otherwise.

---

## Beat 3 · The catalogue, the skill, and the agent

**Run:** `arctl get mcpserver github-mcp`, then the skill, then the `agent()` method.

**Say, first about the catalogue:**

> This is AgentRegistry, and it holds what has been approved. Look at the URL on that
> approved GitHub entry. It is the gateway. It is not `api.githubcopilot.com`.
>
> So a developer who picks GitHub out of the catalogue gets GitHub through the
> enforcement point, and there is no entry in that catalogue that means "GitHub, but
> skip the gateway".

**Then the skill, which is the part people underrate:**

> The catalogue also holds skills, which are approved, versioned guidance. Read a couple
> of lines of this one.
>
> The parameter is `pullNumber` and not `pull_number`. The sandbox has no `Date`. Never
> guess a repository. Do not fetch what cannot change the answer.
>
> Every one of those lines is in there because a run failed without it. Somebody paid
> for each of them once, and now every agent in the organisation gets them for free.

**Then the agent, and this is the beat for a Java room:**

> The agent is Java, on Google ADK, and the whole integration is this one method.
>
> A `StreamableHttpServerParameters` pointing at the gateway. An `McpToolset` built from
> it. An `LlmAgent` with that toolset.
>
> Now look at what is not in there. No GitHub token. No tool list. No policy. The
> gateway owns all three, so none of them are in this file, and none of them need a
> rebuild when they change.

**Cue:** the only local tool is `today`, and it is worth one sentence: the gateway's
sandbox deliberately has no clock, so a program in there cannot work out the date.

**If asked why it is hand-written rather than scaffolded:** `arctl init` does ADK with
Python only today, and `--language java` is rejected. The catalogue does not care,
because an Agent record just references an image, which is what the next beat uses.

**Then build it, in a container:**

> Maven and the JDK run inside the image. There is no Java on this laptop at all.

## Beat 4 · Publish it, deploy it, read the trace

**Run:** `arctl apply -f agent.yaml`, then `arctl apply -f 60-java-deploy-kagent.yaml`,
then wait for Ready. Then switch to the kagent UI, pick **prtriagejava**, paste the
question, and open the Tracing tab.

**Say while it deploys:**

> Two commands. The first publishes the agent to the catalogue. The second is one record
> naming the agent and the runtime.
>
> AgentRegistry does the rest: it creates the kagent Agent, derives the MCP wiring from
> the approved server in the catalogue, and the controller brings the pod up. No Helm
> chart, no hand-written pod spec. Exactly the same two commands a Python agent uses,
> because the registry cares what an agent may call, not what language it is.

**Then ask it the question in the UI, and while it runs:**

> Which of the open pull requests are ready to merge, and what is blocking the rest.

**When the answer lands, do not read the answer. Scroll the trace.**

> This is the bit I want you to look at. Nineteen separate calls. One to list the pull
> requests, then one per pull request to read its discussion. And every one of those
> re-sends the whole conversation so far.
>
> Keep scrolling. That is about eighty thousand bytes of raw GitHub JSON that went
> through the model's context window to produce twenty four lines of report.
>
> Nineteen and not twenty five, by the way, because the approved skill tells it not to
> fetch what cannot change the answer. A draft is already blocked, a held pull request
> is already blocked, so reading their comments buys nothing. The registry saved seven
> calls before the gateway did anything.

**Then the count, which is your accuracy beat:**

> One more thing. Look at the top of the report. It says it scanned twenty five pull
> requests. There are twenty four. It read them one at a time and lost count.
>
> That is small and it is harmless. It is also the shape of the problem: anything the
> model has to hold across nineteen turns is something it can get wrong.

**Cue:** the scroll is the demo. Take your time over it. Ten seconds of silently
scrolling JSON does more work than any sentence here.

## Beat 5 · One field

**Run:** the `toolMode` patch, the `tools/list` cell, the reload, then the same question.

**Say:**

> Same agent. Same image. Same catalogue. One field on the gateway backend.
>
> `toolMode: CodeSearch`. The model no longer gets forty four tools. It gets two:
> `get_tool` to look up an operation's schema, and `run_code` to run a program against
> them.

**Ask the same question again. When it lands:**

> Two round trips. The date, then one program.
>
> That program made eighteen calls to GitHub, inside the gateway, and handed back the
> finished report. Twenty four bytes crossed the context window. Not twenty four
> kilobytes. Twenty four bytes.
>
> Same verdicts on all twenty four pull requests. And the count is right this time, it
> says twenty four, because the program counted them with `.length` instead of the model
> keeping a tally across nineteen turns.

**Then the line the whole talk is built on:**

> Anything the model has to hold is something it can lose. So we stopped giving it
> things to hold.

**Then the sandbox, thirty seconds:**

> Worth knowing what that program is allowed to do. No `fetch`. No `require`. No
> `process`. The only way out of that sandbox is the tool functions the gateway
> generated. A program in there cannot phone home. It can only call approved tools.

**Do not say:** faster. If someone asks about time, answer straight: about the same at
this size, because the saving goes into the model writing the program. What changed is
the round trips and what the model has to carry.

---

## Beat 5b · Answer the heckle

**Run:** the unprepared-question cell.

**Say:**

> Somebody is thinking I wrote that program earlier. So ask it something I obviously did
> not plan for.
>
> Of the pull requests on hold, which was opened earliest?

**When it answers:**

> Different question, different code, still two turns.

**Then, if you have twenty seconds, run it without naming the repository:**

> And when I leave the repository out, it asks me instead of picking one. That is the
> skill again. An agent that guesses a plausible repository gives you an answer that
> looks right and is about somebody else's code.

---

## Beat 6 · Take the write tools away

**Run:** the policy YAML cell, then the apply, then the denied program, then the agent.

**Say:**

> Back to the first slide. Seventeen write tools. This agent needs to read pull
> requests.
>
> That is an `EnterpriseAgentgatewayPolicy`. It names the tools this agent may call, on
> the MCP method name, and it is enforced on the agent's own identity.

**Apply it, then run the denied program:**

> Now watch what happens to the program. Not `403`. Not "permission denied".
>
> `merge_pull_request is not defined`.
>
> The gateway builds that generated API after it applies the policy, so the denied
> operation is not a function in the sandbox at all. The program cannot express the
> call. There is nothing to deny, because there is nothing to try.

**Then ask the agent itself, in the UI:**

> Merge pull request 4, right now, use whatever tool you have.

**When it says it cannot:**

> And the token in that Secret still has every permission it had at the start of this
> talk. It can merge. It can delete files.
>
> The gateway is what makes this agent read-only, and it does it per agent, which no
> token scope can express.

**Close:**

> Three things happened, and none of them happened in the agent's code. It was built
> and shipped from approved parts and never held a credential. The same job went from
> nineteen round trips to two, and stopped getting the count wrong, because the data
> stopped passing through the model. And seventeen write tools went away for this one
> agent, without touching the token.

---

## The numbers, if you get asked

| | Standard | CodeSearch |
|---|---|---|
| tools the model holds | 45 | 2 |
| schema tokens per turn | 14,572 | 1,300 |
| model round trips | 19 | 2 |
| bytes through the model | 80,379 | 24 |
| counted the pull requests correctly | no, said 25 | yes, 24 |

All four `toolMode` settings, and they are two independent choices rather than four
flavours:

| | schemas fetched on demand | all schemas up front |
|---|---|---|
| one operation per call | `Search` | `Standard` |
| one program, many operations | `CodeSearch` | `Code` |

`Search` cuts the catalogue to two tools and 986 tokens, and still takes one call per
operation. `Code` cuts the round trips and carries all forty four signatures in
`run_code`'s description, which is 6,302 tokens. `CodeSearch` does both, at 1,300
tokens and two round trips, which is why the demo uses it.

## Questions you will get

**"Is this just prompt engineering?"** No. The tool list the model receives is
constructed by the gateway, and so is the generated API inside code mode. The agent's
image and its prompt are unchanged across every beat.

**"Could I not filter the tools in my own code?"** You can filter what you pass to the
model. You cannot stop the agent calling a tool it decides to call, because that
decision and that call both happen after your code has run. Beat 6 is enforced on the
wire, on the agent's proven identity.

**"What is in the sandbox?"** `Math`, `JSON`, `Promise`, `Object`, `Array`, `String`,
`Number`, `RegExp`, `BigInt`. Not `Date`, `fetch`, `Map`, `Set`, `console`, `process`,
`require` or `setTimeout`.

**"What are the limits?"** Twenty upstream tool calls per program, and exceeding it
discards the program. Twenty four pull requests fits because drafts and held pull
requests need no comment read.

**"Is it open source?"** kagent and agentregistry are CNCF sandbox projects,
agentgateway is in the Linux Foundation. The `toolMode` settings are an Enterprise field
on `EnterpriseAgentgatewayBackend`. OSS filters which tools a backend exposes, which
keeps the list short by a different route.

**"Why a fork, and why do the pull requests look synthetic?"** Because the answer has to
be the same every run. Say so plainly, it costs nothing: live pull requests on a busy
repository change hour to hour, and the numbers on my slides would stop matching.

**"The CI is red on those pull requests."** Kagent's own workflows run on the fork and
the fixture branches do not build. The gate here is draft, hold label and sign-off
comment, and it does not look at checks. Avoid showing the GitHub pull request list and
this never comes up.

## What not to claim

1. Not faster. Both modes land around thirty seconds at this size.
2. Do not stage the bigger accuracy failure live. Against a live upstream repo the
   default mode twice reported pull requests as ready to merge that had no approval at
   all, and once dropped one and reported seven of eight. It is real, it is measured,
   and it is stochastic. Use it as evidence, demonstrate the miscount instead.
3. Do not say OSS cannot shape tool lists. It can filter which tools a backend exposes.
   Replacing the list with meta tools is the Enterprise part.

## If something breaks

**`Failed to create MCP session`.** DNS. The suite's endpoints are
`*.<lb-ip>.sslip.io`, and resolvers with rebinding protection refuse to return a private
address. Run `agents/prtriage/scripts/fix-cluster-dns.sh`.

**A `toolMode` change seems to do nothing.** The agent lists its tools once at startup.
`agents/prtriage/scripts/reload-agent.sh` restarts it and waits for exactly one
running pod.

**`cannot exec in a deleted state`.** Same script. It happens when a prompt lands on a
pod that is still terminating.

**A rebuilt agent behaves as though nothing changed.** The image is `:latest` and kagent
runs it `IfNotPresent`, so a push on the same tag can reuse the node's cached copy. Drop
it from the nodes and restart:
`for n in $(kind get nodes --name mesh1); do docker exec $n crictl rmi localhost:5001/prtriage-java:latest; done`

**The report is missing a pull request.** The program should build the report text
itself, not hand rows back for the model to format. Twenty four rows transcribed by the
model drops one. Check the skill still says so.

**`ask.sh` dies with `python3: executable file not found`.** It mints the OIDC token by
`kubectl exec`-ing into a pod, and the Java image has no Python. It now falls back to any
pod in the namespace that has it, so this should not recur, but `EXEC_FROM=<agent>`
forces a choice.
