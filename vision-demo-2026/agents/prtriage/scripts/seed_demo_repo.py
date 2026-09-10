#!/usr/bin/env python3
"""Seed the frozen demo pull requests. Driven by seed-demo-repo.sh (see it for why)."""
import json, os, sys, base64, time, urllib.request, urllib.error

REPO = os.environ["REPO"]; PAT = os.environ["PAT"]
FIXTURES = os.environ["FIXTURES"]; RESEED = os.environ.get("RESEED")
API = "https://api.github.com/repos/%s" % REPO

def call(method, path, body=None, tolerate=()):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        "Authorization": "Bearer " + PAT, "Accept": "application/vnd.github+json",
        "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=45) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        msg = e.read().decode()[:400]
        if e.code in tolerate:
            return {"_error": msg, "_code": e.code}
        sys.exit("  ✗ %s %s -> HTTP %s\n     %s" % (method, path, e.code, msg))

def long_body(title, path):
    """Long enough that Standard mode carries real weight through the model, written
    the way a reviewer bot writes: summary, file table, collapsed notes."""
    rows = "\n".join("| `%s` | %s |" % (p, d) for p, d in [
        (path, "the change itself"),
        (path.rsplit(".", 1)[0] + "_test." + path.rsplit(".", 1)[1], "table-driven cases for the new behaviour"),
        ("go/core/internal/telemetry/attributes.go", "records the new attribute on the span"),
        ("go/core/internal/controller/reconciler/validate.go", "rejects the combination that used to panic"),
        ("helm/kagent/values.yaml", "documents the field and its default"),
    ])
    return ("### Summary\n\n%s\n\n"
            "This came out of a thread where the symptom and the cause were three layers "
            "apart, so the change is small but the test is the point: it fails without the "
            "fix and passes with it, and it asserts the boundary rather than the happy "
            "path.\n\n### Files\n\n| File | Why it changed |\n| --- | --- |\n%s\n\n"
            "<details>\n<summary>Reviewer notes</summary>\n\n"
            "- The retry path is shared with the streaming client, so this is behind a "
            "field rather than applied unconditionally.\n"
            "- Backwards compatible: the field defaults to the previous behaviour.\n"
            "- No CRD change, so no chart bump is needed.\n\n</details>\n" % (title, rows))

# Real pull requests carry real discussion, and that matters here for a reason beyond
# looking authentic: the whole point of the demo is that gathering one pull request at
# a time drags every raw response through the model's context. Toy one-line comments
# make Standard mode look fine. These are the size review threads actually are.
THREAD = [
 ("Had a look through this. The change itself is small, but I want to be careful about "
  "the ordering, because the same path is used by the streaming client and that one has "
  "bitten us before.\n\nWalking through it:\n\n1. The guard runs before the config is "
  "swapped, which is right, because the old value is what we need to compare against.\n"
  "2. The error is wrapped rather than returned bare, so the caller keeps the context "
  "about which listener it was.\n3. The metric is incremented once, on the failure path "
  "only, so a healthy reload does not move the counter.\n\nWhat I could not convince "
  "myself of from reading alone is what happens when two reloads land in the same "
  "window. Is the second one guaranteed to see the first one's write, or is that only "
  "true because the reconciler happens to be single threaded today? If it is the "
  "latter, a comment saying so would save the next person the same twenty minutes."),
 ("Tested this locally against a three node cluster and the behaviour matches the "
  "description. Steps, for the record, since the last time we changed this area the "
  "repro was lost:\n\n```\nkubectl apply -f config/samples/basic.yaml\nkubectl "
  "rollout status deploy/controller\nkubectl patch cm/settings --type=merge -p "
  "'{\"data\":{\"timeout\":\"5s\"}}'\nkubectl logs deploy/controller | grep reload\n"
  "```\n\nBefore the change the third step logs a panic roughly one time in four. "
  "After it, the reload is rejected cleanly and the previous config stays live, which "
  "is the behaviour we want. I did not manage to reproduce the panic at all with the "
  "patch applied, across about forty attempts.\n\nOne observation that is not a "
  "blocker: the rejection message names the field but not the value, so an operator "
  "reading it still has to go and look at the ConfigMap to see what they typed. Worth "
  "including the offending value if it is not sensitive."),
 ("Two smaller notes and one question.\n\nThe test table is missing the empty case. "
  "There is a row for one listener and a row for many, but nothing for zero, and zero "
  "is exactly the state during the first reconcile before anything is registered. That "
  "is the path that used to panic, so it seems like the row worth having.\n\nNaming: "
  "`reloadGuard` reads like it guards the reload, but it actually validates the "
  "incoming config and the reload is what calls it. `validateIncoming` or similar "
  "would tell the reader which side of the boundary it sits on.\n\nThe question: are "
  "we intending to backport this? The same code exists on the release branch and the "
  "panic is reachable there too. If yes, it is easier to do it now while the context "
  "is fresh than in three weeks when someone hits it in the field."),
 ("Pulled this into the integration environment for a day. No regressions in the "
  "nightly run, and the reload latency is unchanged within noise (p50 was 41ms before "
  "and 43ms after, p99 moved from 180ms to 176ms, so nothing real).\n\nI do want to "
  "flag one thing for whoever reviews next, because it is easy to miss and it is not "
  "this change's fault: the validation now rejects a config that the CRD schema still "
  "accepts. That is the right way round, since rejecting late is better than panicking, "
  "but it means the API will happily take something the controller then refuses, and "
  "the only place that shows up is the controller log. If we care, the same constraint "
  "wants to be a CEL rule on the CRD so the apply fails at the front door instead."),
]

# Exactly one pull request is signed off, and the sign-off is the FIRST thing in the
# comment, because the rule is "starts with LGTM". The distractor below deliberately
# uses the word mid-sentence on a different pull request: a report that calls that a
# sign-off has not read the rule properly, and it is worth knowing that on a laptop
# rather than on stage.
SIGNOFF = ("LGTM. Read the test first and it is obvious: the assertion is on the bound, "
           "not the value, so it keeps working when the default changes. The docs match "
           "the field name and the example compiles. Happy for this to go in as is.\n\n"
           "For the record I checked the generated reference too, since that is the bit "
           "that usually drifts, and the field description matches the Go comment.")
DISTRACTOR = ("Mostly happy with the direction here. I would normally just say lgtm and "
              "move on, but the shared retry path makes me want a second pair of eyes "
              "before this goes in, so leaving it open deliberately rather than signing "
              "it off.\n\nNothing below is a blocker, they are all things I would "
              "rather fix now than explain later:\n\n- the jitter bound is a magic "
              "number, and it appears twice\n- the log line fires on every attempt, "
              "which will be noisy at the tail\n- the helper is exported but only used "
              "in this package")

repo = call("GET", "")
base = repo["default_branch"]
print("== %s (fork of %s), base branch %s ==" % (REPO, (repo.get("parent") or {}).get("full_name"), base))

# Branches whose pull request we deliberately closed during a reseed. They must not
# count as "already there" below, or a reseed closes everything and then creates
# nothing, leaving an empty repo and a demo with no data.
reseeded = set()
if RESEED == "1":
    for p in call("GET", "/pulls?state=open&per_page=100"):
        if p["head"]["ref"].startswith("demo/"):
            call("PATCH", "/pulls/%d" % p["number"], {"state": "closed"})
            reseeded.add(p["head"]["ref"])
            print("   closed #%d (%s)" % (p["number"], p["head"]["ref"]))
    # the branches go too, otherwise creating the ref fails and the new PR has no head
    for ref in sorted(reseeded):
        call("DELETE", "/git/refs/heads/" + ref, tolerate=(404, 422))
    if reseeded:
        print("   deleted %d branch(es)" % len(reseeded))

base_sha = call("GET", "/git/ref/heads/%s" % base)["object"]["sha"]
for lb in ({"name": "needs-sign-off", "color": "fbca04",
            "description": "Waiting on a maintainer LGTM"},
           {"name": "do-not-merge/hold", "color": "e11d21",
            "description": "Held by a maintainer; do not merge"}):
    call("POST", "/labels", lb, tolerate=(422, 403, 404))

# state=all so a half-finished seed is resumable, minus anything this run just closed.
existing = {p["head"]["ref"]: p["number"]
            for p in call("GET", "/pulls?state=all&per_page=100")
            if p["head"]["ref"] not in reseeded}
made = []
for f in json.load(open(FIXTURES)):
    br = f["branch"]
    if br in existing:
        print("  = #%-4s %s (already there)" % (existing[br], br)); made.append(existing[br]); continue
    call("POST", "/git/refs", {"ref": "refs/heads/" + br, "sha": base_sha}, tolerate=(422,))
    # A .go file containing only comments does not compile, and if the target repo
    # runs CI the pull request picks up a red tick that has nothing to do with the
    # demo and invites a question you cannot answer. Write something valid.
    if f["file"].endswith(".go"):
        pkg = f["file"].rsplit("/", 2)[-2].replace("-", "_")
        body = ("// Fixture for the agentgateway MCP tool-layer demo.\n"
                "// This branch exists so the demo returns the same report every run.\n"
                "package %s\n" % pkg)
    elif f["file"].endswith(".py"):
        body = ('"""Fixture for the agentgateway MCP tool-layer demo."""\n'
                "# This branch exists so the demo returns the same report every run.\n")
    elif f["file"].endswith(".ts"):
        body = ("// Fixture for the agentgateway MCP tool-layer demo.\n"
                "export const demoFixture = true;\n")
    else:
        body = ("<!-- Fixture for the agentgateway MCP tool-layer demo. -->\n"
                "This branch exists so the demo returns the same report every run.\n")
    content = base64.b64encode(body.encode()).decode()
    put = call("PUT", "/contents/" + f["file"],
               {"message": f["title"], "content": content, "branch": br}, tolerate=(422,))
    head_sha = (put.get("commit") or {}).get("sha")
    pr = call("POST", "/pulls", {"title": f["title"], "head": br, "base": base,
                                 "body": long_body(f["title"], f["file"]), "draft": f["draft"]})
    n = pr["number"]; made.append(n)
    head_sha = head_sha or pr["head"]["sha"]

    # The third verdict is a LABEL, and deliberately so. A personal access token
    # cannot write commit statuses or check runs (both 403), and `mergeable` is
    # computed lazily by GitHub so it comes back null often enough to make a live
    # demo unreliable. A hold label is deterministic, arrives free inside
    # list_pull_requests, and `do-not-merge/hold` is the convention Prow put into
    # half the Kubernetes ecosystem, so the audience already knows what it means.
    if f["hold"]:
        call("POST", "/issues/%d/labels" % n, {"labels": ["do-not-merge/hold"]},
             tolerate=(403, 404, 410, 422))

    # Several comments per pull request, so the discussion has the weight a real one
    # has. Comment order matters for exactly one of them: the sign-off must be the
    # thing that starts with LGTM.
    bodies = list(THREAD[: 3 if not f["draft"] else 2])
    if f["signoff"]:
        bodies.append(SIGNOFF)
    elif f["branch"].endswith("token-refresh"):
        bodies.append(DISTRACTOR)     # says "lgtm" mid-sentence; must NOT count
    for body in bodies:
        cm = call("POST", "/issues/%d/comments" % n, {"body": body},
                  tolerate=(403, 404, 410))
        if isinstance(cm, dict) and cm.get("_error"):
            print("     ! comment failed -> %s" % cm["_error"][:90]); break
        time.sleep(0.15)

    if not f["signoff"] and not f["draft"]:
        lb = call("POST", "/issues/%d/labels" % n, {"labels": ["needs-sign-off"]},
                  tolerate=(403, 404, 410, 422))
        if isinstance(lb, dict) and lb.get("_error"):
            print("     ! label failed -> %s" % lb["_error"][:90])
    tag = " (draft)" if f["draft"] else (" (on hold)" if f["hold"] else (" LGTM" if f["signoff"] else ""))
    print("  + #%-4s %-26s%s" % (n, br, tag))
    time.sleep(0.3)

openprs = call("GET", "/pulls?state=open&per_page=100")
print("\n  open pull requests now: %d" % len(openprs))
print("  ✓ point the demo at it:  export DEMO_REPO=%s" % REPO)
