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

When `run_code` is not offered, call the individual tools instead.

## Rules for the program

The sandbox is deliberately small. It is not Node, and it is not your agent.

- Only the GitHub functions exist in there. Your own local tools do **not**:
  calling `today()` inside a program fails with `today is not defined`. Call
  `today` first, in your own turn, then inline the date it returns as a string
  literal in the program.
- Available: `Math`, `JSON`, `Promise`, `Object`, `Array`, `String`, `Number`,
  `RegExp`, `BigInt`.
- Not available: `Date`, `Map`, `Set`, `console`, `fetch`, `require`, `process`,
  `setTimeout`. Use plain objects instead of `Map`.
- A program may make at most **20** upstream tool calls, and exceeding it throws away
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

Give the date the report covers, then a count, then the two lists. Report
`READY` pull requests as bare numbers, and blocked ones as one line each with
the reason and the date it was opened. Nothing else, no preamble.

```
Release report, as of <YYYY-MM-DD>
Scanned: <n> open pull requests

Ready to merge: #<n>, #<n>
Blocked:
  #<n>  opened <YYYY-MM-DD>  no approval
  #<n>  opened <YYYY-MM-DD>  on hold
```

If nothing is ready, write `Ready to merge: none`.
