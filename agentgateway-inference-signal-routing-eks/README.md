# Beyond domain routing: combining signals on agentgateway

Two questions about the same subject, routed to different models. "Explain optimistic
concurrency control in two sentences" goes to the general model. "Two writers report
successful updates but one disappears, diagnose it" goes to the code model. Both are
computer science, so the topic cannot be what separates them.

Layers on [prompt-aware model routing](../agentgateway-inference-model-routing-eks/).
That lab routes by topic and leaves the cluster, the two GPUs, the gateway and the
semantic router in place. This one adds a second signal to the router and one decision
that uses it. No new infrastructure, no second GPU, no new model.

**Editions.** Same as the lab it builds on. The gateway configuration is not touched at
all here, so whichever edition of agentgateway is already running keeps working. The only
file this lab applies is a vLLM Semantic Router values overlay.

## What actually changes

Nothing on the gateway. The `AgentgatewayPolicy`, the `HTTPRoute`, both
`AgentgatewayBackend`s and both vLLM Deployments are untouched, and the client still
sends `"model": "auto"`.

| | Model-routing lab | This lab |
|---|---|---|
| Signals | domain | domain **and** complexity |
| Decisions | 3 | 4 |
| Models | Mistral, Qwen | Mistral, Qwen |
| Gateway config | 1 policy, 1 route | unchanged |
| GPUs | 2 | the same 2 |

The routing table is the same table. What changes is what the router is allowed to know
before it fills it in.

## The complexity signal

vLLM Semantic Router has a native complexity signal, and it needs no extra model. You
give it two banks of example prompts, easy and hard. At startup it embeds every example
once with the mmbert model already on the volume. Per request it embeds the prompt, scores
it against both banks, and subtracts:

```
signal = hard_score - easy_score
```

`threshold` is the line between the bands. Above it the rule returns `hard`, below it
`easy`, and near it `medium`. That is the whole mechanism.

It is an estimate of how a request is phrased against examples you chose. It is not a
measurement of whether a model can answer it. Two consequences worth stating plainly:

- The examples are the definition of the signal, so they need care and they must not be
  reused as tests.
- Keep both banks on the same subjects. If easy is all Python and hard is all distributed
  systems, the signal learns the subject and quietly rediscovers the domain.

## Prerequisites

The model-routing lab working, with both models serving. `00-verify-prereqs.sh` checks it and
stops if not.

## Deploy

```bash
./scripts/00-verify-prereqs.sh    # both models serving, gateway on the semantic router
./scripts/01-deploy.sh          # ~2 min, one Helm upgrade
./scripts/02-test-routing.sh
```

`01-deploy.sh` re-runs that lab's Helm release with one extra values file, and prints the
decisions the router loaded plus the two log lines that prove the classifier is live
rather than merely accepted.

## Testing

```
ID   WHAT THE CASE IS FOR               EXPECT   ANSWERED BY
---- ---------------------------------- -------- ------------------------
T1   basic explanation                  mistral  ok  mistral-small-3.2-24b
T2   diagnostic, same subject as T1     qwen     ok  qwen3-coder-30b
T3   basic Kubernetes                   mistral  ok  mistral-small-3.2-24b
T4   diagnostic Kubernetes              qwen     ok  qwen3-coder-30b
T5   hard vocabulary, basic ask         mistral  ok  mistral-small-3.2-24b
T6   short wording, deeper ask          qwen     ok  qwen3-coder-30b
T7   verbose, still basic               mistral  ok  mistral-small-3.2-24b
T8   non-technical control              mistral  ok  mistral-small-3.2-24b
T9   ambiguous, falls back              mistral  ok  mistral-small-3.2-24b

routed as designed: 9/9
```

T1 and T2 are the result. Same domain, different model.

T5, T6 and T7 are the cases designed to catch a signal that is really measuring something
else. T5 uses hard vocabulary for a basic ask, T6 uses short wording for a deeper one, and
T7 pads a basic question with a request for headings and a glossary. None of them moved
the route the wrong way.

The prompts are held out. None appears in the candidate banks in `yaml/00`.

`./scripts/03-show-signals.sh` prints the score behind each decision:

```
Complexity rule 'basic_request': hard_score=0.611, easy_score=0.940, signal=-0.329, difficulty=easy
Complexity rule 'basic_request': hard_score=0.960, easy_score=0.480, signal=0.480, difficulty=hard
```

### Priority, not file order

T1, T5 and T7 each match **two** decisions: `basic_technical_decision` at priority 50 and
`coding_decision` at priority 10, because both test `domain = computer science`. The
specific rule wins because its priority is higher. The router's strategy is `priority`,
so moving decisions around in the file changes nothing.

## Restore

```bash
./scripts/99-restore.sh
```

Re-runs the release with the model-routing lab's values alone. It reads the state back afterwards and
fails if the complexity classifier is still initialised, because a Helm exit code does
not prove a rollback.

## Things that will catch you

| | |
|---|---|
| **Helm replaces lists, it does not merge them** | A `decisions:` list in an overlay drops the ones already there. The router logs the shorter list and nothing reports an error. `yaml/00` therefore carries all four decisions, not just the new one. |
| **`easy` and `hard` are objects, not lists** | They take `{candidates: [...]}`. A bare list is rejected with `cannot unmarshal !!seq into config.ComplexityCandidates`. |
| **Validate before you roll** | `POST /config/router/validate` on the router's API returns the exact unmarshal error. It is much faster than discovering a bad shape through a rollout. |
| **The classification REST API panics when no decision matches** | `/api/v1/classify/*` hits a nil pointer in its keyword fallback and drops the connection with no response. The ExtProc path the gateway uses is not affected and falls back correctly, which is why `02-test-routing.sh` goes through the gateway rather than the API. |
| **A `medium` result is not `easy`** | The rule returns three bands. A decision testing `:easy` does not match `medium`, and the request falls through to the broader rule. That is deliberate: an uncertain request keeps the behaviour it had before. |
| **Do not tune against the test set** | The candidate banks configure the signal and the T-prompts measure it. Moving the threshold until the table goes green and then publishing the table measures nothing. |

## Where this stops

Every decision here has exactly one model in `modelRefs`, so there is no candidate
selection to configure and no selector artifact to train. The router also supports
projections, multi-candidate decisions and learned selectors. Those are a bigger subject
and are not in scope.
