---
name: release-report
description: How to work out which open pull requests are ready to merge and which are blocked, and how to format the answer. Use when asked about release readiness, open PRs, review status, or what is holding a release up.
---

# Release report

Approved guidance for reporting on open pull requests. The platform team worked
out these rules once, against the gateway the tools actually sit behind, so no
agent has to rediscover them.

## Never guess the repository

The question names the repository. Use exactly that one. If it does not name one, say
so and ask, and do not call anything. Picking a plausible repository and reporting on it
produces an answer that looks right and is about somebody else's code, which is worse
than no answer.

## Gather the data in one program, not one call at a time

The GitHub tools reach you through agentgateway. When the gateway offers a
`run_code` tool, use it: write one JavaScript program that fetches and filters
everything, and return only the finished answer. Do not call one tool per pull
request. A twenty-pull-request report is three programs, not forty-one turns.

This is not only about speed. Gathering one pull request at a time puts every raw API
response into the conversation, and by the time you come to write the report the
review data is tens of thousands of tokens behind you and easy to lose. Filter in the
program, where the data cannot drift out of reach.

## When there is no `run_code` tool

Look at what the gateway does offer. If it offers `get_tool` and `invoke_tool`, the
operations are reached through those and the section below on them applies. Otherwise
the operations are offered directly, as one tool each.

Either way you are now calling one thing at a time, so read comments for **every** pull
request that is neither a draft nor on hold. There is no call budget in
this mode: the twenty-call limit below is a property of the sandbox a program runs in,
and it does not apply to tools you call turn by turn. Twenty four pull requests with
three drafts and four holds is one list call and seventeen comment reads, and all
seventeen have to happen.

A pull request whose comments you did not read has an unknown verdict, not a verdict of
`no sign-off`. If you find yourself about to report one you did not read, read it.

## Rules for the program

The sandbox is deliberately small. It is not Node, and it is not your agent.

- Only the GitHub functions exist in there. Your own local tools do **not**:
  calling `today()` inside a program fails with `today is not defined`. Call
  `today` first, in your own turn, then inline the date it returns as a string
  literal in the program.
- Available: `Math`, `JSON`, `Promise`, `Object`, `Array`, `String`, `Number`,
  `RegExp`, `BigInt`.
- The program's value is its last expression. To return an object, wrap it in
  parentheses: `({number: 12, title: t})`. A bare `{number: 12}` in statement position
  is a block with a label in it, not an object, and the program comes back empty or
  throws. That failure sends the model round again, and a retry is where a turn is most
  likely to break.
- Emit one tool call per turn. Two in the same turn is how a conversation ends up with
  a tool call that has no result attached to it, and the next request is rejected.
- Not available: `Date`, `Map`, `Set`, `console`, `fetch`, `require`, `process`,
  `setTimeout`. Use plain objects instead of `Map`.
- A program may make at most **20** upstream tool calls (a sandbox limit, and only a
  sandbox limit), and exceeding it throws away
  the whole program, so budget before you write. One `list_pull_requests` plus one `get_comments`
  for each pull request that still needs one (see below) means **nineteen** pull
  requests needing comments fit in the first program, and twenty in any program after
  that. Drafts and held pull requests cost nothing.

### Do not fetch what cannot change the answer

`draft` and the hold label both arrive in the `list_pull_requests` response, and either
one decides the verdict on its own. So **only read comments for pull requests that are
neither a draft nor on hold.** A sign-off cannot rescue a draft, and it cannot lift a
hold, so those calls buy nothing.

That is not a micro-optimisation, it is usually what makes the whole job fit. Twenty
four pull requests with three drafts and four holds is one list call plus seventeen
comment reads, which is eighteen calls and fits in a single program. Fetch all
twenty four and you are at twenty five, over the cap, and the program is discarded.

### Read every one of them, and count

The other half of that rule is that you must read **all** of the ones that qualify. A
comment read is the only thing that can turn a verdict into `READY`, so a pull request
you did not read is not "no sign-off", it is unknown, and reporting it as a verdict is
wrong.

Before you write the report, compare two numbers: how many pull requests are neither
draft nor held, and how many comment reads you actually did. If the second is smaller,
go back and read the rest. Do not fill the gap with an assumption, and do not stop
early because the answers are long and repetitive.

### When the job does not fit in one program

Do not fall back to calling one tool at a time. Split it:

1. **First program.** Call `list_pull_requests` once, classify as many pull requests as
   the budget allows, and return two things: the finished rows, and the raw
   `{ number, draft, labels, created_at }` for the ones you did not reach. Those come
   free from the list call, so carrying them forward costs nothing.
2. **Later programs.** Take the numbers you were handed, read their comments, return
   their rows. Do not call `list_pull_requests` again.
3. Concatenate the rows and write one report.

Two programs cover 34 pull requests and three cover 52, which is still two or three
model turns rather than fifty. That is the point.
- Filter, sort and aggregate inside the program. Return the smallest value that
  answers the question, never a raw tool response.
- **Never use `return` at the top level.** The program is a script, not a function, and
  a top-level `return` fails to compile and costs you the whole run. Assign to a
  variable and leave that variable as the last expression.

## If the server offers get_tool and invoke_tool

That is the gateway handing you a searchable catalogue instead of every tool at once.
**Call `get_tool` for a tool before you first `invoke_tool` it**, and use the argument
names it gives back. Do not guess them. `get_tool` takes an object with a `name`
string, `{ "name": "list_pull_requests" }`, and a bare string is rejected as "tool input
must be a JSON object". Guessing `per_page` instead of `perPage`, or
folding the owner into `repo` as `"owner/repo"`, costs a full retry of the call, and
the pull request list is the largest response in this job.

## The response shapes, so you do not have to guess

Getting these wrong costs a whole retry, so they are written down:

- `list_pull_requests` returns an **array** of pull requests.
- `list_pull_requests` returns an **array**, and each item carries the `fields` you
  asked for, including `labels`.
- `pull_request_read` with `method: "get_comments"` returns an **array** of comments,
  each with a `body`. Guard with `Array.isArray` before calling `.filter`, `.map` or
  `.some` on anything.

## How to judge a pull request

The parameter is `pullNumber`, not `pull_number`. Getting the name wrong costs a retry.

Two of the three signals arrive free in the pull request list, so ask for them:

- `list_pull_requests` with
  `fields: ["number","title","draft","created_at","labels"]` gives you `draft` and
  `labels` for every pull request in one call.
- `pull_request_read` with `method: "get_comments"` gives you one pull request's
  discussion. A pull request is signed off when a comment body starts with `LGTM`.

Evaluate all three conditions **independently**, then take the first that is true. Do
not chain them as `else if` on a response shape: a guard like
`else if (Array.isArray(comments))` is true whenever comments came back at all, which
swallows every test after it and reports a blocked pull request as READY. Compute the
booleans first, then decide:

```js
const isDraft   = pr.draft === true;
const onHold    = (Array.isArray(pr.labels) ? pr.labels : [])
  .some((l) => (typeof l === "string" ? l : l.name) === "do-not-merge/hold");
const signedOff = (Array.isArray(comments) ? comments : [])
  .some((c) => String(c.body || "").trim().toUpperCase().startsWith("LGTM"));

let verdict = "READY";
if (isDraft) verdict = "draft";
else if (onHold) verdict = "on hold";
else if (!signedOff) verdict = "no sign-off";
```

`labels` may come back as strings or as objects with a `name`, so handle both.

A comment that merely discusses the change is not a sign-off. Only `LGTM` at the start
of a comment counts.

Dates are `YYYY-MM-DD`, ten characters. `created_at` comes back as a full ISO
timestamp, so cut it: `String(pr.created_at).slice(0, 10)`. Do not print the time.

**Report every pull request you were given.** If the list returned eight, the report
has eight lines across the two sections. Losing one is worse than being slow.

## Let the program write the report

Build the finished report text **inside the program** and return it as a string. Do not
return rows for yourself to format afterwards.

This costs a few more lines of JavaScript and it is worth every one of them. Returning
twenty four rows and formatting them in your own reply means transcribing twenty four
lines by hand, and a transcription of twenty four lines drops one. That has been
measured here: the program returned all twenty four pull requests and the report came
out with twenty three.

Anything the program hands back is something you can lose. So hand back the answer,
not the ingredients.

## House format for the answer

Lead with the counts, then the detail. Somebody reading this wants to know how bad it
is before they read two dozen lines.

Say the count out loud from the data (`length`), never from memory of how many you
looked at.

```
Release report, as of <YYYY-MM-DD>

<n> pull requests checked against the demo release gate

Ready:             <n>
Draft:             <n>
On hold:           <n>
Awaiting sign-off: <n>

Ready: #<n>, #<n>

Blocked:
  #<n>  opened <YYYY-MM-DD>  draft
  #<n>  opened <YYYY-MM-DD>  on hold
  #<n>  opened <YYYY-MM-DD>  no sign-off
```

If nothing is ready, write `Ready: none`. Dates are ten characters, no time.

**Call it the demo release gate, not merge readiness.** This gate is draft status, the
hold label and a sign-off comment. It does not look at review approvals, at CI, or at
branch protection, so a pull request that passes it is not necessarily mergeable on
GitHub. Say what was actually checked.
