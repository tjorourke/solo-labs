#!/usr/bin/env python3
"""Compare a release report against the live fixture state. See check-report.sh."""
import json, os, re, sys, urllib.request

REPO, PAT, REPORT = os.environ["REPO"], os.environ["PAT"], os.environ["REPORT"]


def gh(path):
    req = urllib.request.Request(
        "https://api.github.com/repos/%s%s" % (REPO, path),
        headers={"Authorization": "Bearer " + PAT,
                 "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=45) as r:
        return json.loads(r.read())


def truth():
    """What the fixture actually says, by the same rules the skill gives the agent."""
    out = {}
    for pr in gh("/pulls?state=open&per_page=100"):
        n = pr["number"]
        labels = {l["name"] for l in pr.get("labels", [])}
        signed = any(
            (c.get("body") or "").strip().upper().startswith("LGTM")
            for c in gh("/issues/%d/comments" % n))
        if pr["draft"]:
            v = "draft"
        elif "do-not-merge/hold" in labels:
            v = "on hold"
        elif not signed:
            v = "no sign-off"
        else:
            v = "READY"
        out[n] = v
    return out


def reported():
    """The verdicts the agent printed, from the last report in the transcript."""
    text = open(REPORT, errors="replace").read()
    # The transcript contains the PROGRAM as well as its output, and the program builds
    # the report with template literals, so "Release report" appears in both. Take the
    # last occurrence that is at the start of a line, which is the rendered answer.
    starts = [m.start() for m in re.finditer(r"^Release report", text, re.M)]
    if not starts:
        starts = [m.start() for m in re.finditer(r"Release report", text)]
    tail = text[starts[-1]:] if starts else text
    verdicts = {}
    for n, v in re.findall(r"^[\s\-*]*#(\d+)\s+opened\s+\S+\s+(.+?)\s*$", tail, re.M):
        verdicts[int(n)] = v.strip().rstrip("*").strip()
    # Either wording, and only the list line: the compact summary also has a
    # "Ready:             2" count line, which must not be read as a pull request list.
    # \**$ at the end too: a model that bolds the whole line writes "**Ready: #35**",
    # and without it the trailing asterisks break the match and the pull request reads
    # as never reported.
    ready = re.search(r"^\**Ready(?: to merge)?:\**\s*(#[\d,\s#]+?)\**$", tail, re.M)
    for n in re.findall(r"#(\d+)", ready.group(1) if ready else ""):
        verdicts[int(n)] = "READY"
    scanned = re.search(r"Scanned:\**\s*(\d+)", tail)
    return verdicts, (int(scanned.group(1)) if scanned else None)


want = truth()
got, scanned = reported()

print("  fixture: %d open pull requests" % len(want))
tally = {}
for v in want.values():
    tally[v] = tally.get(v, 0) + 1
print("  expected: " + ", ".join("%s %d" % (k, tally[k]) for k in sorted(tally)))

problems = []
if scanned is not None and scanned != len(want):
    problems.append("the report says it scanned %d, there are %d" % (scanned, len(want)))

missing = sorted(set(want) - set(got))
if missing:
    problems.append("not reported at all: %s" % ", ".join("#%d" % n for n in missing))

extra = sorted(set(got) - set(want))
if extra:
    problems.append("reported but not open: %s" % ", ".join("#%d" % n for n in extra))

# "no approval" and "no sign-off" are the same verdict in different words, and the
# model picks either. Judge the decision, not the phrasing.
def same(a, b):
    # "awaiting sign-off" is the wording the house format uses in the SUMMARY block, and
    # a model that carries it down into the rows has said exactly the same thing. Treat
    # it as the same verdict rather than failing a report that is right.
    def norm(v):
        v = re.sub(r"\s*\(.*\)$", "", v).strip()
        if v.startswith("no ") or v.startswith("awaiting"):
            return "no sign-off"
        return v
    return norm(a) == norm(b)

wrong = [(n, want[n], got[n]) for n in sorted(set(want) & set(got))
         if not same(want[n], got[n])]
for n, w, g in wrong:
    problems.append("#%d: fixture says '%s', report says '%s'" % (n, w, g))

if problems:
    print("  ✗ the report does NOT match the fixture:")
    for p in problems:
        print("      - " + p)
    sys.exit(1)
print("  ✓ every one of the %d pull requests matches the fixture" % len(want))
