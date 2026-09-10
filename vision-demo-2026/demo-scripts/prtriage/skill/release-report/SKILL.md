---
name: release-report
description: How to work out which open pull requests are ready to merge and which are blocked, and how to format the answer. Use when asked about release readiness, open PRs, review status, or what is holding a release up.
---

# Release report

Approved guidance for reporting on open pull requests. The platform team worked
out these rules once, against the gateway the tools actually sit behind, so no
agent has to rediscover them.

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
  the whole program. Budget with headroom: one `list_pull_requests` plus two calls per
  pull request means **eight** pull requests per program, which is 17 calls. Nine is
  19 and leaves you one slip from losing the run. If more are needed, run a second
  program.
- Filter, sort and aggregate inside the program. Return the smallest value that
  answers the question, never a raw tool response.

## If the server offers get_tool and invoke_tool

That is the gateway handing you a searchable catalogue instead of every tool at once.
**Call `get_tool` for a tool before you first `invoke_tool` it**, and use the argument
names it gives back. Do not guess them. Guessing `per_page` instead of `perPage`, or
folding the owner into `repo` as `"owner/repo"`, costs a full retry of the call, and
the pull request list is the largest response in this job.

## The response shapes, so you do not have to guess

Getting these wrong costs a whole retry, so they are written down:

- `list_pull_requests` returns an **array** of pull requests.
- `pull_request_read` with `method: "get_reviews"` returns an **array** of
  reviews, each with a `state` field.
- `pull_request_read` with `method: "get_check_runs"` returns an **object**:
  `{ total_count, check_runs: [ { name, status, conclusion } ] }`. Read
  `.check_runs`, and guard with `Array.isArray` before calling `.filter` or
  `.map` on anything.

## How to judge a pull request

The parameter is `pullNumber`, not `pull_number`. Getting it wrong costs a retry.

Read reviews with `pull_request_read` (`method: "get_reviews"`) and checks with
`pull_request_read` (`method: "get_check_runs"`).

Then evaluate all three conditions **independently** and pick the first that is
true. Do not chain them as `else if` on the response shape: a guard like
`else if (Array.isArray(checks.check_runs))` is true whenever checks came back at
all, which swallows the approval test and reports an unapproved pull request as
READY. Compute the booleans first, then decide:

```js
const isDraft  = pr.draft === true;
const failing  = (Array.isArray(checks.check_runs) ? checks.check_runs : [])
  .filter((c) => ["failure","timed_out","cancelled","action_required"].includes(c.conclusion));
const approved = (Array.isArray(reviews) ? reviews : [])
  .some((r) => r.state === "APPROVED");

let verdict = "READY";
if (isDraft) verdict = "draft";
else if (failing.length > 0) verdict = "checks failing (" + failing.length + ")";
else if (!approved) verdict = "no approval";
```

A review with state `COMMENTED` or `CHANGES_REQUESTED` is **not** an approval.

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
  #<n>  opened <YYYY-MM-DD>  checks failing (2)
```

If nothing is ready, write `Ready to merge: none`.
