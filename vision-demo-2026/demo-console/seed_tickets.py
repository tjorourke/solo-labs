#!/usr/bin/env python3
"""Create tjorourke/network-slice-manager and the 24 open PRs the demo reports.

Idempotent. Needs `gh` logged in with repo scope.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data" / "mcp-demo.json"
REPO = os.environ.get("DEMO_REPO", "tjorourke/network-slice-manager")
WORKDIR = Path(os.environ.get("DEMO_WORKDIR", "/tmp/network-slice-manager"))

LABELS = {
    "ready": ("ready-to-merge", "16a34a", "Ready to merge"),
    "work": ("needs-work", "d97706", "Needs work"),
    "block": ("do-not-merge", "dc2626", "Do not merge"),
}

NOTE_LABELS = {
    "failing e2e": ("failing-e2e", "b91c1c"),
    "missing review": ("missing-review", "b45309"),
    "legal hold": ("legal-hold", "7f1d1d"),
    "WIP": ("wip", "64748b"),
    "security freeze": ("security-freeze", "b91c1c"),
    "spike": ("spike", "7c3aed"),
    "lab only": ("lab-only", "334155"),
    "licence review": ("licence-review", "b45309"),
}


def run(cmd, cwd=None, check=True):
    return subprocess.run(cmd, cwd=cwd, check=check, text=True, capture_output=True)


def gh(*args, check=True):
    return run(["gh", *args], check=check)


def slug(title: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return s[:48]


def ensure_repo():
    view = gh("repo", "view", REPO, "--json", "url", check=False)
    if view.returncode != 0:
        print(f"creating {REPO}")
        gh(
            "repo", "create", REPO,
            "--public",
            "--description", "Demo 5G network slice manager. Frozen open PRs for the Token economics MCP demo.",
            "--disable-wiki",
            "--add-readme",
        )
    else:
        print(f"repo exists {REPO}")
    if WORKDIR.exists():
        run(["git", "-C", str(WORKDIR), "fetch", "origin"], check=False)
        run(["git", "-C", str(WORKDIR), "checkout", "main"], check=False)
        run(["git", "-C", str(WORKDIR), "pull", "--ff-only"], check=False)
    else:
        gh("repo", "clone", REPO, str(WORKDIR))
    run(["git", "config", "user.email", "tom@orourkeonline.co.uk"], cwd=WORKDIR)
    run(["git", "config", "user.name", "Tom O'Rourke"], cwd=WORKDIR)
    readme = WORKDIR / "README.md"
    if not readme.exists() or "Token economics" not in readme.read_text():
        readme.write_text(
            "# network-slice-manager\n\n"
            "Demo 5G network-slice control plane used for a live Token economics "
            "MCP walkthrough. The open pull requests are the release report: "
            "ready to merge, needs work, and do not merge.\n"
        )
        run(["git", "add", "README.md"], cwd=WORKDIR)
        st = run(["git", "status", "--porcelain"], cwd=WORKDIR)
        if st.stdout.strip():
            run(["git", "commit", "-m", "Add the demo README."], cwd=WORKDIR)
            run(["git", "push", "-u", "origin", "HEAD"], cwd=WORKDIR)


def ensure_labels():
    existing = json.loads(gh("label", "list", "--repo", REPO, "--json", "name").stdout)
    have = {x["name"] for x in existing}
    wanted = [(a, b, c) for a, b, c in LABELS.values()]
    wanted += [(name, color, name) for name, color in NOTE_LABELS.values()]
    for name, color, desc in wanted:
        if name in have:
            continue
        gh("label", "create", name, "--repo", REPO, "--color", color, "--description", desc, check=False)


def existing_prs():
    raw = gh(
        "pr", "list", "--repo", REPO, "--state", "open", "--limit", "100",
        "--json", "number,title,url",
    ).stdout
    return {p["title"]: p for p in json.loads(raw)}


def pr_body(title, group, note):
    why = {
        "ready": "Checks are green. Review is in. This can go in the next slice drop.",
        "work": "Still open. Do not merge until the note below is cleared.",
        "block": "Must not merge. Held on purpose.",
    }[group]
    note_line = f"\n\nCurrent gate: **{note}**." if note else ""
    return (
        f"### Summary\n\n{title}.\n\n{why}{note_line}\n\n"
        "This is a demo change on the slice manager used for the Token economics "
        "walkthrough. The file in the PR is enough for GitHub MCP to list, read "
        "and classify it.\n"
    )


def file_for(title, note):
    return (
        f"# {title}\n\n"
        f"{note or 'Change for the next network-slice drop.'}\n"
    )


def commit_status(sha, state, context, desc):
    gh(
        "api", f"repos/{REPO}/statuses/{sha}",
        "-f", f"state={state}",
        "-f", f"context={context}",
        "-f", f"description={desc}",
        check=False,
    )


def comment(number, body):
    gh("pr", "comment", str(number), "--repo", REPO, "--body", body, check=False)


def ensure_pr(item, group, have):
    title = item["title"]
    note = item.get("note") or ""
    branch = "demo/" + slug(title)
    if title in have:
        print(f"  exists #{have[title]['number']}  {title}")
        return have[title]
    run(["git", "checkout", "main"], cwd=WORKDIR)
    run(["git", "checkout", "-B", branch], cwd=WORKDIR)
    rel = Path("changes") / (slug(title) + ".md")
    (WORKDIR / rel).parent.mkdir(exist_ok=True)
    (WORKDIR / rel).write_text(file_for(title, note))
    run(["git", "add", str(rel)], cwd=WORKDIR)
    run(["git", "commit", "-m", title], cwd=WORKDIR)
    run(["git", "push", "-u", "origin", branch], cwd=WORKDIR)
    sha = run(["git", "rev-parse", "HEAD"], cwd=WORKDIR).stdout.strip()
    args = [
        "pr", "create", "--repo", REPO, "--base", "main", "--head", branch,
        "--title", title, "--body", pr_body(title, group, note),
        "--label", LABELS[group][0],
    ]
    if note == "WIP":
        args.append("--draft")
    extra = NOTE_LABELS.get(note)
    if extra:
        args.extend(["--label", extra[0]])
    out = gh(*args)
    print(out.stdout.strip() or f"  opened {title}")
    # number from the URL at the end
    url = (out.stdout.strip().split() or [""])[-1]
    number = None
    m = re.search(r"/pull/(\d+)", url)
    if m:
        number = int(m.group(1))
    if note in ("failing e2e", "flaky"):
        commit_status(sha, "failure", "e2e", note)
    elif group == "ready":
        commit_status(sha, "success", "e2e", "checks green")
    if note == "open comments":
        comment(number, "The 5QI remap still needs a second look on voice bearers before this can merge.")
    if note == "missing review":
        comment(number, "URSP policy change. Waiting on a reviewer from core.")
    if note == "legal hold":
        comment(number, "Legal hold. Do not merge until lawful intercept has signed off.")
    return {"title": title, "number": number, "url": url}


def write_back(created):
    data = json.loads(DATA.read_text())
    by_title = {p["title"]: p for p in created}
    report = data["report"]
    report["repo"] = REPO
    n = 0
    for g in report["groups"]:
        for it in g["items"]:
            p = by_title.get(it["title"])
            if p and p.get("number"):
                it["n"] = p["number"]
                it["url"] = p.get("url") or f"https://github.com/{REPO}/pull/{p['number']}"
                n += 1
    report["open"] = n
    data["repo"] = REPO
    data["prompt"] = f"Give me the release report for {REPO}, all open pull requests."
    DATA.write_text(json.dumps(data, indent=2) + "\n")
    print(f"wrote {n} PR numbers into {DATA}")


def main():
    data = json.loads(DATA.read_text())
    ensure_repo()
    ensure_labels()
    created = []
    have = existing_prs()
    for g in data["report"]["groups"]:
        print("==", g["label"])
        for it in g["items"]:
            created.append(ensure_pr(it, g["id"], have))
            have = existing_prs()
    live = existing_prs()
    for p in created:
        if p["title"] in live:
            p["number"] = live[p["title"]]["number"]
            p["url"] = live[p["title"]]["url"]
    write_back(created)
    print("https://github.com/" + REPO)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        sys.stderr.write(e.stderr or e.stdout or str(e))
        sys.exit(e.returncode)
