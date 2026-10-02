"""GitHub tools for the TrustUsBank PM and engineer agents, sized for Gemma's 8k context.

The general GitHub MCP server returns whole issue and file payloads, which an 8k
window cannot hold alongside a system prompt. These are the few calls the SDLC loop
needs, each answering in a few hundred tokens, scoped to one repo.

    ROLE          pm   list_issues, get_app_settings, create_issue
                  dev  get_next_issue, read_file, update_setting, edit_file, open_pull_request
    GITHUB_TOKEN  from a Secret, never logged
    REPO          tjorourke/trustusbank-payments

The flow the labels carry: the PM files a spec as `spec-review`; a human approves it
to `agent-ready` (or rejects it: `spec-rejected`, closed). The engineer commits to
`agent/issue-<n>`, never to main, and opens a pull request that closes the issue,
which moves to `in-review`. The console stages the PR head; a human approves (merge,
promote) or denies (a comment, and the issue back to `agent-ready`).
"""
import base64
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request

from mcp_base import serve

ROLE = os.environ.get("ROLE", "pm")
REPO = os.environ.get("REPO", "tjorourke/trustusbank-payments")
MAIN = os.environ.get("BRANCH", "main")
STAGING = os.environ.get("STAGING_URL", "http://staging.payments.agentic.eu0.internal")
PROD = os.environ.get("PROD_URL", "http://payments.agentic.eu0.internal")
API = "https://api.github.com"
FOOTER = "\n\n---\n"   # everything after this in an issue body is ours, not the PM's
PAGES = ("index", "accounts", "payments", "cards", "loans", "help")
EDITABLE = ("config.json", *(f"site/{p}.html" for p in PAGES), "site/assets/site.css", "site/assets/site.js",
            "static/index.html", "static/styles.css", "static/app.js")


def gh(method, path, body=None):
    tok = os.environ.get("GITHUB_TOKEN", "")
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + tok,
                                          "Accept": "application/vnd.github+json",
                                          "User-Agent": "trustusbank-sdlc-mcp"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise ValueError(f"GitHub returned 404 for {path}: missing, or the token cannot see {REPO}")
        raise ValueError(f"GitHub {e.code}: {e.read()[:200].decode('utf-8', 'replace')}")
    except urllib.error.URLError as e:
        raise ValueError(f"cannot reach GitHub: {e.reason}")


def branch_of(n):
    return f"agent/issue-{int(n)}"


def _branch_sha(name):
    try:
        return gh("GET", f"/repos/{REPO}/git/ref/heads/{urllib.parse.quote(name)}")["object"]["sha"]
    except ValueError:
        return None


def _ensure_branch(n):
    """The issue's working branch, cut from main the first time the engineer commits."""
    name = branch_of(n)
    if not _branch_sha(name):
        gh("POST", f"/repos/{REPO}/git/refs", {"ref": f"refs/heads/{name}", "sha": _branch_sha(MAIN)})
    return name


def _file(path, ref):
    f = gh("GET", f"/repos/{REPO}/contents/{path}?ref={urllib.parse.quote(ref)}")
    return base64.b64decode(f["content"]).decode(), f["sha"]


def _commit(path, text, sha, message, branch):
    r = gh("PUT", f"/repos/{REPO}/contents/{path}", {
        "message": message, "branch": branch, "sha": sha,
        "content": base64.b64encode(text.encode()).decode()})
    return r["commit"]["sha"][:7]


def _check(path, text):
    if path.endswith(".json"):
        json.loads(text)
    elif path.endswith(".html") and "</html>" not in text:
        raise ValueError(f"{path} would no longer end in </html>: edit a smaller piece")


def _labels(n, add, remove):
    for r in remove:
        try:
            gh("DELETE", f"/repos/{REPO}/issues/{n}/labels/{r}")
        except ValueError:
            pass
    gh("POST", f"/repos/{REPO}/issues/{n}/labels", {"labels": [add]})


def _open_pr(n):
    owner = REPO.split("/")[0]
    prs = gh("GET", f"/repos/{REPO}/pulls?state=open&head={owner}:{urllib.parse.quote(branch_of(n))}")
    return prs[0] if prs else None


def _issue_number(a):
    try:
        return int(a.get("issue_number"))
    except (TypeError, ValueError):
        raise ValueError("issue_number is required: the number get_next_issue returned")


# ── PM ───────────────────────────────────────────────────────────────────────
def list_issues(a):
    out = gh("GET", f"/repos/{REPO}/issues?state={a.get('state', 'open')}&per_page=10")
    return {"issues": [{"number": i["number"], "title": i["title"], "state": i["state"],
                        "labels": [l["name"] for l in i["labels"]]}
                       for i in out if "pull_request" not in i]}


STYLESHEETS = ("site/assets/site.css", "static/styles.css")


def _theme(path):
    """The colour variables in a stylesheet's :root block, so a spec can name the
    real ones (--brand) instead of guessing (--primary-color)."""
    text, _ = _file(path, MAIN)
    root = re.search(r":root\s*{([^}]*)}", text)
    return dict(re.findall(r"(--[\w-]+)\s*:\s*(#[0-9A-Fa-f]{3,8})\s*;", root.group(1))) if root else {}


def get_app_settings(a):
    text, _ = _file("config.json", MAIN)
    return {"config.json": json.loads(text),
            "website_pages": [f"site/{p}.html" for p in PAGES],
            "online_banking": ["static/index.html", "static/styles.css", "static/app.js"],
            "theme_colours": {p: _theme(p) for p in STYLESHEETS}}


def create_issue(a):
    title = str(a.get("title") or "").strip()
    if not title:
        raise ValueError("title is required")
    body = str(a.get("body") or "").strip() + FOOTER + (
        f"**Staging:** {STAGING}  \n**Production:** {PROD}\n\n"
        "Filed by the TrustUsBank PM agent (Gemma 3 27B on Google Cloud Dedicated, Berlin). "
        "Labelled `spec-review`: a human approves the spec before the engineer agent picks it up.")
    i = gh("POST", f"/repos/{REPO}/issues", {"title": title[:120], "body": body, "labels": ["spec-review"]})
    return {"number": i["number"], "url": i["html_url"], "label": "spec-review"}


# ── engineer ─────────────────────────────────────────────────────────────────
def get_next_issue(a):
    out = gh("GET", f"/repos/{REPO}/issues?labels=agent-ready&state=open&sort=created&direction=asc&per_page=1")
    if not out:
        return {"issue": None, "note": "no agent-ready issues"}
    i = out[0]
    n = i["number"]
    comments = [c["body"] for c in gh("GET", f"/repos/{REPO}/issues/{n}/comments?per_page=100")]
    pr = _open_pr(n)
    if pr:
        comments += [c["body"] for c in gh("GET", f"/repos/{REPO}/issues/{pr['number']}/comments?per_page=100")]
    branch = branch_of(n)
    text, _ = _file("config.json", branch if _branch_sha(branch) else MAIN)
    return {"number": n, "title": i["title"],
            "body": (i.get("body") or "").split(FOOTER)[0][:1200],
            "recent_comments": [c[:400] for c in comments[-3:]],
            "branch": branch, "pull_request": pr["number"] if pr else None,
            "config.json": json.loads(text),
            "files": list(EDITABLE)}


def read_file(a):
    path = str(a.get("path") or "")
    if path not in EDITABLE:
        raise ValueError(f"path must be one of {', '.join(EDITABLE)}")
    branch = branch_of(a["issue_number"]) if a.get("issue_number") else MAIN
    text, _ = _file(path, branch if _branch_sha(branch) else MAIN)
    lines = text.splitlines()
    find = str(a.get("find") or "")
    if find:
        hits = [n for n, l in enumerate(lines) if find.lower() in l.lower()]
        if not hits:
            return {"path": path, "error": f"'{find}' not found"}
        start = max(0, hits[0] - 5)
    else:
        start = max(0, int(a.get("start") or 1) - 1)
    chunk = lines[start:start + 40]
    return {"path": path, "lines": f"{start + 1}-{start + len(chunk)} of {len(lines)}",
            "text": "\n".join(chunk)}


def update_setting(a):
    n = _issue_number(a)
    key = str(a.get("key") or "").strip()
    value = a.get("value")
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError:
            pass   # a plain string, such as an announcement
    branch = _ensure_branch(n)
    text, sha = _file("config.json", branch)
    cfg = json.loads(text)
    node, parts = cfg, key.split(".")
    for p in parts[:-1]:
        node = node.get(p) if isinstance(node, dict) else None
    if not isinstance(node, dict) or parts[-1] not in node:
        flat = [k for k, v in cfg.items() if not isinstance(v, dict)] + \
               [f"{k}.{s}" for k, v in cfg.items() if isinstance(v, dict) for s in v]
        raise ValueError(f"unknown setting '{key}'; settings are {', '.join(flat)}")
    old = node[parts[-1]]
    if old is not None and not isinstance(value, type(old)) and not (
            isinstance(old, (int, float)) and isinstance(value, (int, float)) and not isinstance(value, bool)):
        raise ValueError(f"{key} is a {type(old).__name__}, got {json.dumps(value)}")
    node[parts[-1]] = value
    msg = str(a.get("message") or f"Set {key} to {json.dumps(value)}")
    commit = _commit("config.json", json.dumps(cfg, indent=2, ensure_ascii=False) + "\n", sha,
                     f"{msg} (#{n})", branch)
    return {"committed": commit, "branch": branch, "key": key, "old": old, "new": value}


def edit_file(a):
    n = _issue_number(a)
    path, find, repl = str(a.get("path") or ""), str(a.get("find") or ""), str(a.get("replace") or "")
    if path not in EDITABLE:
        raise ValueError(f"path must be one of {', '.join(EDITABLE)}")
    if not find:
        raise ValueError("find is required: the exact text to replace")
    branch = _ensure_branch(n)
    text, sha = _file(path, branch)
    count = text.count(find)
    if count != 1:
        raise ValueError(f"find must match exactly once in {path}; it matched {count} times. "
                         "Call read_file and copy a longer, exact piece of one line.")
    new = text.replace(find, repl)
    _check(path, new)
    commit = _commit(path, new, sha, f"{a.get('message') or 'Edit ' + path} (#{n})", branch)
    return {"committed": commit, "branch": branch, "path": path}


def open_pull_request(a):
    n = _issue_number(a)
    summary = str(a.get("summary") or "Implemented.").strip()[:800]
    branch = branch_of(n)
    # Gemma often asks for the commit and the pull request in one turn, and the runtime
    # runs them side by side: give the commit a moment to land before giving up.
    main = _branch_sha(MAIN)
    for _ in range(10):
        head = _branch_sha(branch)
        if head and head != main:
            break
        time.sleep(2)
    if not head:
        raise ValueError(f"nothing committed on {branch} yet: call update_setting or edit_file first")
    if head == main:
        raise ValueError(f"{branch} has no changes against {MAIN}")
    pr = _open_pr(n)
    if pr:
        gh("POST", f"/repos/{REPO}/issues/{pr['number']}/comments", {"body":
            f"**Updated by the engineer agent** at `{head[:7]}` after review.\n\n{summary}"})
    else:
        issue = gh("GET", f"/repos/{REPO}/issues/{n}")
        pr = gh("POST", f"/repos/{REPO}/pulls", {
            "title": f"{issue['title']} (#{n})", "head": branch, "base": MAIN,
            "body": f"Closes #{n}\n\n{summary}\n\n---\nOpened by the TrustUsBank engineer agent "
                    "(Gemma 3 27B on Google Cloud Dedicated, Berlin). The platform builds this "
                    f"branch and stages it at {STAGING}; a human approves before it merges and "
                    f"reaches {PROD}."})
    gh("POST", f"/repos/{REPO}/issues/{n}/comments", {"body":
        f"**Pull request #{pr['number']}** from `{branch}` at `{head[:7]}`: {pr['html_url']}\n\n{summary}"})
    _labels(n, "in-review", ("agent-ready",))
    return {"issue": n, "pull_request": pr["number"], "url": pr["html_url"], "commit": head[:7],
            "label": "in-review"}


def T(name, desc, props, required=()):
    return {"name": name, "description": desc, "inputSchema": {
        "type": "object", "properties": {k: {"type": t, "description": d} for k, (t, d) in props.items()},
        "required": list(required)}}


ISSUE = ("integer", "the issue number from get_next_issue")
TOOLS = {
    "pm": [
        T("list_issues", "List up to 10 issues in the TrustUsBank website repo.",
          {"state": ("string", "open, closed or all; default open")}),
        T("get_app_settings", "The site's settings (config.json: limits, features, announcement, "
          "support phone) and its page files.", {}),
        T("create_issue", "File a spec as a GitHub issue, labelled spec-review for human approval.",
          {"title": ("string", "short imperative title"),
           "body": ("string", "the requirement and acceptance criteria, in markdown")}, ("title", "body")),
    ],
    "dev": [
        T("get_next_issue", "The oldest agent-ready issue, its latest comments (including review "
          "denials), its branch and pull request, the current config.json and the editable files.", {}),
        T("update_setting", "Change one setting in config.json on the issue's branch. Use for limits, "
          "feature flags, the announcement banner and the support phone.",
          {"issue_number": ISSUE,
           "key": ("string", "dotted key, e.g. features.instant_payments or daily_transfer_limit_eur"),
           "value": ("string", "the new value as JSON: true, 10000, or \"text\""),
           "message": ("string", "commit message")}, ("issue_number", "key", "value", "message")),
        T("read_file", "Read 40 lines of a website file, from the issue's branch if it has one.",
          {"path": ("string", "e.g. site/index.html or static/styles.css"), "find": ("string", "optional text to jump to"),
           "start": ("integer", "optional first line"), "issue_number": ISSUE}, ("path",)),
        T("edit_file", "Replace one exact, unique piece of text in a website file, on the issue's branch.",
          {"issue_number": ISSUE, "path": ("string", "file path"),
           "find": ("string", "exact text, must occur once"), "replace": ("string", "replacement text"),
           "message": ("string", "commit message")}, ("issue_number", "path", "find", "replace", "message")),
        T("open_pull_request", "After committing: open (or update) the pull request that closes the "
          "issue, and move the issue to in-review.",
          {"issue_number": ISSUE, "summary": ("string", "what changed, one or two sentences")},
          ("issue_number", "summary")),
    ],
}
CALLS = {"list_issues": list_issues, "get_app_settings": get_app_settings, "create_issue": create_issue,
         "get_next_issue": get_next_issue, "read_file": read_file, "update_setting": update_setting,
         "edit_file": edit_file, "open_pull_request": open_pull_request}

if __name__ == "__main__":
    names = {t["name"] for t in TOOLS[ROLE]}
    serve(f"trustusbank-sdlc-{ROLE}", TOOLS[ROLE], {k: v for k, v in CALLS.items() if k in names})
