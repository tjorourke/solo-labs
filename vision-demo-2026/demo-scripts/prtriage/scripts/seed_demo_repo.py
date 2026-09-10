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

SIGNOFF = ("LGTM. Read the test first and it is obvious: the assertion is on the bound, "
           "not the value, so it keeps working when the default changes. The docs match "
           "the field name. Happy for this to go in.")
HOLD = ("Left this in the queue for now. The change reads fine, but I want the failure "
        "reproduced in a test before signing off, and the shared retry path makes me want "
        "a second pair of eyes on the streaming client too.")

repo = call("GET", "")
base = repo["default_branch"]
print("== %s (fork of %s), base branch %s ==" % (REPO, (repo.get("parent") or {}).get("full_name"), base))

if RESEED == "1":
    for p in call("GET", "/pulls?state=open&per_page=100"):
        if p["head"]["ref"].startswith("demo/"):
            call("PATCH", "/pulls/%d" % p["number"], {"state": "closed"})
            print("   closed #%d" % p["number"])

base_sha = call("GET", "/git/ref/heads/%s" % base)["object"]["sha"]
for lb in ({"name": "needs-sign-off", "color": "fbca04",
            "description": "Waiting on a maintainer LGTM"},
           {"name": "do-not-merge/hold", "color": "e11d21",
            "description": "Held by a maintainer; do not merge"}):
    call("POST", "/labels", lb, tolerate=(422, 403, 404))

existing = {p["head"]["ref"]: p["number"] for p in call("GET", "/pulls?state=all&per_page=100")}
made = []
for f in json.load(open(FIXTURES)):
    br = f["branch"]
    if br in existing:
        print("  = #%-4s %s (already there)" % (existing[br], br)); made.append(existing[br]); continue
    call("POST", "/git/refs", {"ref": "refs/heads/" + br, "sha": base_sha}, tolerate=(422,))
    content = base64.b64encode(
        ("// %s\n// Fixture for the agentgateway MCP tool-layer demo.\n"
         "// This branch exists so the demo returns the same report every run.\n"
         % f["file"]).encode()).decode()
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

    cm = call("POST", "/issues/%d/comments" % n,
              {"body": SIGNOFF if f["signoff"] else HOLD}, tolerate=(403, 404, 410))
    if isinstance(cm, dict) and cm.get("_error"):
        print("     ! comment failed (issues disabled?) -> %s" % cm["_error"][:90])
    if not f["signoff"] and not f["draft"]:
        lb = call("POST", "/issues/%d/labels" % n, {"labels": ["needs-sign-off"]},
                  tolerate=(403, 404, 410, 422))
        if isinstance(lb, dict) and lb.get("_error"):
            print("     ! label failed -> %s" % lb["_error"][:90])
    tag = " (draft)" if f["draft"] else (" (on hold)" if f["hold"] else (" LGTM" if f["signoff"] else ""))
    print("  + #%-4s %-26s%s" % (n, br, tag))
    time.sleep(1)

openprs = call("GET", "/pulls?state=open&per_page=100")
print("\n  open pull requests now: %d" % len(openprs))
print("  ✓ point the demo at it:  export DEMO_REPO=%s" % REPO)
