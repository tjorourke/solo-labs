# Part 8 · Build, ship and govern an agent

Spoken guide.

What to say, in order, while `demo-8-github-agent.ipynb` runs. Roughly twelve minutes.

The sentences in the **Say** blocks are meant to be said close to as written. Everything
else is a cue. Numbers are measured on `mesh1` against `tjorourke/kagent`, twenty four
seeded pull requests, `claude-sonnet-4-5`, agentgateway `v2026.8.2`. The agent is **Java on
Google ADK**.

The two claims that hold on every single run, and the only two to build on:

1. Seventeen tool calls become one.
2. Seventy seven thousand bytes through the model become two thousand.

**Read both off the trace on the day.** They are an order of magnitude apart every run,
which is the claim. The exact figure is not, because the model chooses how to batch.

Do not claim it is faster. Both land around thirty seconds and somebody will time you.

---

## Verify these two in rehearsal, they cannot be checked from a terminal

1. **The Tracing tab actually draws the tree.** The Java agent now initialises the
   OpenTelemetry SDK from the variables kagent injects, and its spans do land in the
   table the UI reads: `call_llm` and `execute_tool <name>`, the same names the Python
   agent produces. Confirmed in ClickHouse. What is not confirmed is the tab rendering
   them, because that needs a browser. Look at it once before you rely on it.
2. **The report a viewer sees in the UI**, as opposed to the one `ask.sh` prints. They
   come from the same A2A response, but only one of them has been looked at.

## Before you start

1. Run the **Connect** cell at the bottom of the notebook, then
   **`./agents/prtriage/scripts/preflight.sh`**. Connect is
   `source agents/prtriage/connect.sh`, and that same line works pasted into a terminal
   from any directory, so the notebook and a terminal give you the same shell. It puts
   `mcp`, `ask`, `try-merge` and the rest on `PATH` and writes a kubeconfig holding only
   this cluster, which is why every cell can say plain `kubectl`. It changes nothing in
   the cluster, so re-run it whenever, including mid-demo. Preflight checks the fixture
   counts, the catalogue, both agents, both MCP paths, model access, stray policies left
   over from a previous run, and whether traces are landing. If it says "ready to
   present", it is. If not, every failure line says what to fix.
   `./agents/prtriage/scripts/setup.sh` is cluster setup, not a beat: run it well before
   you present. It builds the waypoint, both backends, the route and the catalogue
   entries, and you never touch it on stage.
2. Run beat 1 once to warm the path, then `./agents/prtriage/scripts/reset.sh`, which
   puts `toolMode` back to `Standard` and deletes any policy.
3. Confirm the repo still has twenty four open pull requests, four held, three drafts.
4. Have the `tools/list` output captured to a file as a fallback.
5. Windows you want open: the notebook, the kagent UI, a terminal, and optionally the
   pull request list at `github.com/tjorourke/kagent/pulls`, which is clean.

---

## Beat 1 · What one MCP server costs you

**Run:** the `tools/list` cell, then the token count cell.

**Say:**

> I wanted an agent that could tell me which pull requests were ready to merge. So I
> connected GitHub's MCP server, which is one server, and this is what turned up.
>
> Ninety three tools. Thirty one thousand tokens of tool definitions, counted by
> Anthropic's own endpoint rather than estimated, and that is in the context on every
> single turn, before anyone has typed a question.
>
> Thirty one of those ninety three can write. `create_or_update_file`. `push_files`.
> `delete_file`. `merge_pull_request`. `actions_run_trigger`, which starts a CI job.
>
> I did not choose any of that. I connected one server.

**Cue:** read the three write tool names slowly. That is the moment the room goes quiet.

**If asked "can't you filter those in your agent?":**

> You can, and a careful team will. The platform does it once for every agent, and
> refuses a direct call that skips the model's tool list. That last part is the bit
> agent-side filtering cannot do, and we finish on it.

---

## Beat 2 · The gateway holds the credential

**Run:** the backend cell, then the no-credential call.

**Say:**

> Before we build anything, one piece of plumbing. That is agentgateway in front of
> GitHub's MCP server, read straight out of the cluster. Two fields matter.
> `protocol: StreamableHTTP`, because GitHub's server is hosted and speaks that. And
> `policies.auth.secretRef`, which is where the token lives.
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

**Run:** `arctl get mcpserver` and `arctl get skill`, then the skill's headings, then
`make -C agents/prtriage/java-agent show`.

**Say, first about the catalogue:**

> This is AgentRegistry, and it holds what has been approved: the servers, the skills,
> the agents. The approved GitHub entry points at the gateway, in the cluster. There is
> no entry that means `api.githubcopilot.com` directly.
>
> So a developer who picks GitHub out of the catalogue gets GitHub through the
> enforcement point, and there is no entry in that catalogue that means "GitHub, but
> skip the gateway".

**Then the skill, which is the part people underrate:**

> The catalogue also holds skills, which are approved, versioned guidance. These are the
> headings of this one, and each heading is a rule.
>
> Never guess the repository. Gather the data in one program. Do not fetch what cannot
> change the answer. Let the program write the report.
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

**If asked why it is hand-written:** `arctl init` does Python only today. The catalogue
does not care, an Agent record just references an image.

**Then build it, in a container:**

> Maven and the JDK run inside the image. There is no Java on this laptop at all.

## Beat 4 · Publish it, deploy it, read the trace

**Run:** the two `arctl apply` commands, which publish the agent and deploy it, then
wait for Ready. Then switch to the kagent UI, pick **prtriagejava**, paste the question,
and open the Tracing tab.

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

> This is the bit I want you to look at. Read the count off the screen. One call to
> list the pull requests, then one per pull request to read its discussion, and every
> one of those re-sends the whole conversation so far.
>
> Keep scrolling. That is tens of thousands of bytes of raw GitHub JSON that went
> through the model's context window to produce a four-line summary.
>
> Eighteen and not twenty five, by the way, because the approved skill tells it not to
> fetch what cannot change the answer. A draft is already blocked, a held pull request
> is already blocked, so reading their comments buys nothing. The registry saved seven
> calls before the gateway did anything.

**Say what the gate is, so "ready" is not overclaiming:**

> The gate here is: not a draft, not held, signed off. It does not look at approvals or
> CI. These are seeded pull requests so the same inputs run twice.

**Then check it rather than assert it:**

> And rather than trust that report, this reads the fixture straight from GitHub and
> compares it line by line.

**Whatever it says, say that, and move on in one sentence.** Five runs in six it matches
the fixture exactly, and the beat is the eighteen round trips either way. The sixth drops
a row from the report or mislabels one, because writing twenty four rows by hand is the
model's job in this mode. If that is the run you get, say so plainly and let the next
beat answer it. Never script a mistake, and never lean on getting one.

**Cue:** the scroll is the demo. Take your time over it. Ten seconds of silently
scrolling JSON does more work than any sentence here.

## Beat 5 · One field

**Run:** the `toolMode` patch cell, which also waits and reloads, then the `tools/list`
cell, then the same question.

**Say:**

> Same agent. Same image. Same catalogue. One field on the gateway backend.
>
> `toolMode: CodeSearch`. The model no longer gets forty four tools. It gets two:
> `get_tool` to look up an operation's schema, and `run_code` to run a program against
> them. And the agent restarts, because it reads its tool list once at startup. Same
> image digest, and the line says so.

**Ask the same question again. When it lands:**

> One round trip. One program.
>
> That program made eighteen calls to GitHub, inside the gateway, and handed back the
> finished report. Two thousand bytes crossed the context window instead of eighty
> thousand, and the two thousand is the report itself.
>
> Same verdicts on all twenty four pull requests, and every row is there, because the
> program wrote the report with the data in front of it instead of the model
> transcribing twenty four lines from eighteen turns ago.

**Then the line the whole talk is built on:**

> Anything the model has to hold is something it can lose. So we stopped giving it
> things to hold.

**One line of honesty, if the room looks sceptical:**

> This does not make the model correct. It writes JavaScript and JavaScript can be
> wrong. What it does is keep the raw data out of the context window.

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

## Beat 6 · Two agents, one integration, different permissions

**Run:** the policy, then the release agent, then `identity-matrix`, then `try-merge`
for both.

**Say, while the policy goes on:**

> The triage agent reads pull requests. A release agent needs to merge them. Both use
> the same approved GitHub integration, the same image, and the same skill.
>
> This is enforced at the waypoint, and that detail matters. A waypoint receives the
> connection from ztunnel and can read the peer certificate, so the identity in this
> policy is who the workload provably is, not what it claims to be. An ingress gateway
> cannot do that, because by then the connection has left the mesh. It is the same
> reason Part 4 enforces its access policy at a waypoint.

**Then deploy the second agent and show the matrix:**

> Second agent. Same image. Different identity.
>
> Each of them runs the same one-line program in the gateway's sandbox, from its own
> pod, asking which GitHub functions exist in there. Same URL, same body, no credentials
> anywhere. The only thing that differs is who is asking.

```
  identity           read PRs   merge        functions in its sandbox
  triage agent       yes        not defined  list_pull_requests pull_request_read
  release agent      yes        DEFINED      list_pull_requests merge_pull_request ...
  changelog agent    DENIED     DENIED       (the gateway generated no functions at all)
```

> For the triage agent `merge_pull_request` is not a function that exists. The release
> agent has it. And the third one is another team's agent, which has been running in
> this cluster the whole time, wired to the same approved GitHub server. It gets nothing
> at all.
>
> The gateway generates that API after it applies the policy, so this table is the
> policy, read back out of the sandbox.

### The enforcement proof, which is the bit that counts

**Run `try-merge` for both.**

**Say:**

> An agent telling you it cannot merge is the model being agreeable. So this sends the
> request the model would have made, straight at the gateway, from inside the agent's
> own pod. It carries the real identity and it goes nowhere near the model.

**Then read the two results out, slowly, because the contrast is the point:**

> As the triage agent: `merge_pull_request is not defined`. Not a 403, and not a refusal
> from GitHub. The program cannot express the call, so nothing left the cluster.
>
> As the release agent: the error names `api.github.com`, and it is a 404. That request
> went all the way to GitHub, and the only thing that stopped it was the pull request
> not existing.
>
> Same request. Same gateway. Different identity.

**Cue:** the pull request number does not exist, so a policy failure could only 404.
Only mention it if someone asks whether you just merged something.

**Then the credential point, in the corrected form:**

> And the credential has not moved. That PAT can merge and delete files for either of
> them. GitHub's permissions bound what the credential can ever do; gateway policy gives
> each agent using that one integration a different set of tool permissions, which is a
> distinction GitHub has no way to express.

### The agent that was never approved for it

**Run the changelog agent cell.** This is the one to slow down on, because it is the
question every platform team is actually asking.

**Say:**

> Same question, same cluster, different agent. Watch what it does.
>
> It writes the program, exactly like the triage agent did. And
> `list_pull_requests is not defined`. So it asks the gateway what tools it can have,
> and gets an empty list back. Not an error, not a 403. An empty catalogue.
>
> Then it tells me it cannot do the job, which is the right answer and not one it had
> to be taught.

**Cue:** the agent does not hallucinate a report. Worth saying out loud, because the
room will be wondering.

**Then how the gateway knows, which is the question underneath all of it:**

> Nothing in that request says who is calling. The agent has no credential and no name
> to send, and there is no header it could set to claim one. What it has is a
> certificate, issued to its pod, and ztunnel presents it. The waypoint terminates that
> connection and reads the identity off the certificate.
>
> Those are the SPIFFE names on screen, counted by the gateway itself. That is the
> thing the policy matches, and an agent cannot present one it was not issued.

**Cue:** the identity column and the SPIFFE column are the same names. Point at both.
An ingress gateway cannot do this, because by then the connection has left the mesh,
which is why the approved catalogue entry sends agents to the in-cluster name.

**Then the scoping, which is the bit to talk over:**

> This agent is in the catalogue. It is wired to the same approved GitHub server. Every
> part of its deployment looks correct, and it starts fine.
>
> Being in the catalogue is not permission. AgentRegistry decides what an agent may be
> wired to. The gateway decides what it may call. Two questions, two layers, and you
> want both: one team's agent being allowed to reference GitHub should not mean it can
> merge your pull requests.
>
> The identity is the service account, and it is not something the agent chooses. Add
> fifty more agents to this cluster tomorrow and none of them appear in that expression,
> so none of them get a single tool. It fails closed by default, not by vigilance.

**Finish on useful access, not on the denial:**

> The triage agent still does its job.

Run the report one more time and let it land. A demo that ends on a refusal leaves the
room thinking about what they cannot do.

**Close:**

> AgentRegistry supplied the approved integration. kagent deployed and ran the agent.
> agentgateway changed how it used tools and enforced what it could call.
>
> The agent image stayed the same.

## The numbers, if you get asked

| | Standard | CodeSearch |
|---|---|---|
| tools the model holds | 94 | 3 |
| schema tokens per turn | 30,904 | 1,606 |
| model round trips | 17 | 1 |
| bytes through the model | 77,498 | 2,288 |
| matches the fixture | five runs in six | six in six |

All four `toolMode` settings, and they are two independent choices rather than four
flavours:

| | schemas fetched on demand | all schemas up front |
|---|---|---|
| one operation per call | `Search` | `Standard` |
| one program, many operations | `CodeSearch` | `Code` |

`Search` cuts the catalogue to two tools and 1,292 tokens, and still takes one call per
operation. `Code` cuts the round trips and carries all ninety three signatures in
`run_code`'s description, which is 11,748 tokens. `CodeSearch` does both, at 1,606
tokens and one round trip, which is why the demo uses it.

The scaling is the argument. Going from GitHub's default 44 tools to all 93 took
`Standard` from 14,572 tokens a turn to 30,904. It took `CodeSearch` from 1,300 to
1,606. Twice the tools, twice the tax, unless something else is holding them.

## Questions you will get

**"Is this just prompt engineering?"** No. The tool list the model receives is
constructed by the gateway, and so is the generated API inside code mode. The agent's
image and its prompt are unchanged across every beat.

**"Can't you just turn off the tools you don't need?"** GitHub lets you, and it is a
better dial than people expect: `X-MCP-Toolsets: pull_requests` gets 10 tools,
`/mcp/x/pull_requests/readonly` gets 3. Measured. Two things it cannot do. It is a
toolset and not a tool, so `pull_requests` includes `merge_pull_request` unless you go
read-only across the whole connection. And it is one answer for everyone on that
connection, so it cannot give the triage agent and the release agent different lists,
which is beat 6. The demo asks for all 93 deliberately, with a header the gateway sets,
because that is what an organisation ends up with once one team needs Actions and
another needs Dependabot.

**"Could I not filter the tools in my own code?"** Yes, and a careful team will. The
difference is that the platform applies it once, outside the agent, the same way for
every agent, and refuses a direct call that skips the model's tool list altogether.
Beat 6's denied request never went near the model.

**"What stops the agent just calling api.github.com directly?"** At the network layer,
in this lab, nothing, and you should say so rather than be caught by it. What stops it
being worth doing is that the credential is not in the pod. I have tested the bypass:
from inside the agent, a direct call to GitHub reads public repositories, cannot read a
private one, and cannot write anything at all. So going around the gateway costs it
every repository you care about and every verb that changes something.

If you want the network closed too, that is an egress control rather than a tool
control: a NetworkPolicy or an ambient egress policy allowing the agent to reach the
waypoint, the model endpoint and the kagent controller, and nothing else. Worth knowing
before you try it live that an ambient egress policy has to allow istiod and istio-csr
as well, or certificate renewal fails about forty five minutes later and the mesh stops
working long after the change looked fine.

**"Where does the identity come from?"** ztunnel, from the workload's SPIFFE
certificate. The policy matches `source.identity.serviceAccount`, and the agent has no
say in it. Worth knowing that this only works at a waypoint: at an ingress gateway the
connection has left the mesh and the identity is gone, which is why the approved
catalogue entry points agents at the in-cluster name.

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

**"What about CI?"** The reseeded pull requests carry no check status at all, so there
are no red ticks to explain and the GitHub UI is safe to project. The honest answer is
that the demo gate does not look at checks: it is draft, hold label and sign-off.

## What not to claim

1. Not faster. Both modes land around thirty seconds at this size.
2. Do not build the beat on the default mode getting it wrong. It gets it right five
   runs in six, and the sixth fails differently each time: a dropped row, a mislabelled
   verdict, a total that does not match. Real, measured, and stochastic. The check cell
   reports whichever you got, in one line; the beat is the round trips.
3. Do not say OSS cannot shape tool lists. It can filter which tools a backend exposes.
   Replacing the list with meta tools is the Enterprise part.

## If something breaks

**`Failed to create MCP session`.** DNS. The suite's endpoints are
`*.<lb-ip>.sslip.io`, and resolvers with rebinding protection refuse to return a private
address. Run `agents/prtriage/scripts/fix-cluster-dns.sh`.

**A `toolMode` change seems to do nothing.** The agent lists its tools once at startup.
`reload-agent` restarts it and waits for exactly one running pod.

**`cannot exec in a deleted state`.** Same script. It happens when a prompt lands on a
pod that is still terminating.

**A rebuilt agent behaves as though nothing changed.** The image is `:latest` and kagent
runs it `IfNotPresent`, so a push on the same tag could reuse the node's cached copy.
`make push` now drops it from every node, and `reload-agent` compares the digest it
built with the digest the pod came back on and fails loudly if they differ. If you see
that failure, run `make -C agents/prtriage/java-agent push` again.

**`tool_use ids were found without tool_result blocks`.** The model emitted two tool
calls in one turn, or retried a program that threw. The skill tells it to send one call
per turn and to wrap a returned object in parentheses, which is what triggered it. Ask
again; a new question gets a new session.

**The report is missing a pull request.** The program should build the report text
itself, not hand rows back for the model to format. Twenty four rows transcribed by the
model drops one. Check the skill still says so.

**`ask.sh` dies with `python3: executable file not found`.** It mints the OIDC token by
`kubectl exec`-ing into a pod, and the Java image has no Python. It now falls back to any
pod in the namespace that has it, so this should not recur, but `EXEC_FROM=<agent>`
forces a choice.
