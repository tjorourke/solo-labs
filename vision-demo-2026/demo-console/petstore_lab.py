#!/usr/bin/env python3
"""Agent-SDLC demo: pm-bot files a GitHub issue, dev-bot implements it, the platform
builds and stages the result, a human approves or denies, and approving promotes the
exact staged image to prod. See agents_lab.py for the agent deploy/chat plumbing this
reuses; this module only does the deterministic infra work around it.
"""
from __future__ import annotations

import json
import subprocess
import tempfile
import threading
import time
from pathlib import Path

import agents_lab as al

REPO = "tjorourke/demo-petstore"
REPO_URL = f"https://github.com/{REPO}.git"
IMAGE = "localhost:5001/demo-petstore"
MESH = al.MESH
STATE_FILE = al.DATA / "petstore-state.json"


def _load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except json.JSONDecodeError:
            pass
    return {"stage": "idle"}


def _save_state(state: dict) -> None:
    STATE_FILE.write_text(json.dumps(state, indent=2))


def _gh(*args, timeout=30):
    return subprocess.run(["gh", *args], capture_output=True, text=True, timeout=timeout)


def latest_agent_ready_issue() -> dict | None:
    """The oldest open issue still waiting for a developer, read straight from GitHub
    rather than trusted from an agent's reply -- the UI's own source of truth."""
    p = _gh("issue", "list", "--repo", REPO, "--label", "agent-ready", "--state", "open",
            "--json", "number,title,url,createdAt", "--limit", "20")
    if p.returncode != 0:
        return None
    issues = json.loads(p.stdout or "[]")
    if not issues:
        return None
    issues.sort(key=lambda i: i["createdAt"])
    return issues[0]


def latest_in_review_issue() -> dict | None:
    """The issue dev-bot most recently committed against, however many are open --
    build_and_stage() always builds the current HEAD, so only the newest matters."""
    p = _gh("issue", "list", "--repo", REPO, "--label", "in-review", "--state", "open",
            "--json", "number,title,url", "--limit", "20")
    if p.returncode != 0 or not p.stdout.strip():
        return None
    issues = json.loads(p.stdout or "[]")
    return issues[-1] if issues else None


_AUTOSTAGE_INFLIGHT = set()
_AUTOSTAGE_LOCK = threading.Lock()


def _autostage_if_needed(issue: dict | None, staging_tag: str | None) -> None:
    """Whatever got an issue to in-review -- the console's own fetch, someone chatting
    to dev-bot directly, a bare curl to its A2A endpoint, a manual push -- staging
    should never depend on remembering which one does the build. Every status() poll
    (the page calls this every 8s) checks the real HEAD against what's actually
    running, and stages it itself if they've drifted. Runs in the background: status()
    has to return fast, and a docker build does not."""
    if not issue:
        return
    head = _resolve_head_sha()
    if not head or (staging_tag or "").startswith(head):
        return
    with _AUTOSTAGE_LOCK:
        if issue["number"] in _AUTOSTAGE_INFLIGHT:
            return
        _AUTOSTAGE_INFLIGHT.add(issue["number"])

    def run():
        try:
            build_and_stage()
        finally:
            with _AUTOSTAGE_LOCK:
                _AUTOSTAGE_INFLIGHT.discard(issue["number"])

    threading.Thread(target=run, daemon=True).start()


def status() -> dict:
    state = _load_state()
    state["agent_ready_issue"] = latest_agent_ready_issue()
    issue = latest_in_review_issue()
    state["in_review_issue"] = issue
    for env, ns in (("staging", "petstore-staging"), ("prod", "petstore-prod")):
        img = al.kc("-n", ns, "get", "deploy/petstore",
                    "-o", "jsonpath={.spec.template.spec.containers[0].image}", check=False)
        state[f"{env}_image"] = (img.stdout or "").strip().split(":")[-1] if img.returncode == 0 else None
    _autostage_if_needed(issue, state.get("staging_image"))
    return state


DEFAULT_FETCH_PROMPT = (
    "Check demo-petstore for new agent-ready issues. If you find one, "
    "implement it end to end: read the files, make the change, commit it with "
    "push_files, comment with the result, and set the label to in-review with "
    "issue_write."
)


def fetch_and_implement(text: str | None = None):
    """Hand dev-bot an instruction to look for its own work and implement it -- the
    canned prompt by default, or whatever the presenter typed instead. Yields the same
    small events chat_stream() already yields, for the UI to show live as a real chat."""
    state = _load_state()
    state["stage"] = "implementing"
    _save_state(state)
    yield from al.chat_stream("dev-bot", (text or "").strip() or DEFAULT_FETCH_PROMPT)
    state = _load_state()
    state["stage"] = "implemented"
    _save_state(state)


def _ar_ingress_lb() -> str:
    p = al.kc("-n", "agentgateway-system", "get", "gateway", "ar-ingress",
             "-o", "jsonpath={.status.addresses[0].value}", check=False)
    return (p.stdout or "").strip()


def staging_url() -> str:
    return f"http://petstore-staging.{_ar_ingress_lb()}.sslip.io/"


def prod_url() -> str:
    return f"http://petstore-prod.{_ar_ingress_lb()}.sslip.io/"


def _resolve_head_sha() -> str | None:
    p = subprocess.run(["git", "ls-remote", REPO_URL, "refs/heads/main"],
                       capture_output=True, text=True, timeout=20)
    if p.returncode != 0 or not p.stdout.strip():
        return None
    return p.stdout.split()[0][:12]


def build_and_stage() -> dict:
    """Build the repo's current HEAD and roll it out to petstore-staging. The sha comes
    from git, never from dev-bot's own reply -- a deterministic anchor an LLM's prose
    formatting can't break."""
    sha = _resolve_head_sha()
    if not sha:
        return {"ok": False, "error": "could not resolve demo-petstore's HEAD"}
    tag = f"{sha}-{int(time.time())}"
    with tempfile.TemporaryDirectory() as td:
        clone = subprocess.run(["git", "clone", "--depth", "1", REPO_URL, td],
                               capture_output=True, text=True, timeout=60)
        if clone.returncode != 0:
            return {"ok": False, "error": (clone.stderr or "clone failed")[:300]}
        build = subprocess.run(["docker", "build", "-q", "-t", f"{IMAGE}:{tag}", td],
                               capture_output=True, text=True, timeout=180)
        if build.returncode != 0:
            return {"ok": False, "error": (build.stderr or "docker build failed")[:500]}
        push = subprocess.run(["docker", "push", f"{IMAGE}:{tag}"],
                              capture_output=True, text=True, timeout=120)
        if push.returncode != 0:
            return {"ok": False, "error": (push.stderr or "docker push failed")[:500]}
    set_img = al.kc("-n", "petstore-staging", "set", "image", "deploy/petstore",
                    f"petstore={IMAGE}:{tag}", check=False)
    if set_img.returncode != 0:
        return {"ok": False, "error": (set_img.stderr or "kubectl set image failed")[:300]}
    al.kc("-n", "petstore-staging", "rollout", "status", "deploy/petstore", "--timeout=60s", check=False)
    state = _load_state()
    state["stage"] = "staged"
    state["staged_tag"] = tag
    state["staged_sha"] = sha
    _save_state(state)
    issue = latest_in_review_issue()
    if issue:
        url = staging_url()
        _gh("issue", "comment", str(issue["number"]), "--repo", REPO,
            "--body", f"Staged for review at commit `{sha}`: {url}\n\nApprove or deny from the "
                      f"demo console's Agent SDLC page.")
    return {"ok": True, "tag": tag, "sha": sha, "issue": issue, "staging_url": staging_url()}


def promote(approve: bool, reason: str = "") -> dict:
    """Approve: the exact tag already reviewed in staging goes to prod, no rebuild.
    Deny: prod is untouched, the reason is the only record of what to fix, and the
    label goes back to agent-ready so a future "fetch latest" hands it to dev-bot
    again -- without that flip the issue would just sit in in-review forever with
    no way back into the loop."""
    state = _load_state()
    tag = state.get("staged_tag")
    issue = latest_in_review_issue()
    if approve:
        if not tag:
            return {"ok": False, "error": "nothing staged to promote"}
        set_img = al.kc("-n", "petstore-prod", "set", "image", "deploy/petstore",
                        f"petstore={IMAGE}:{tag}", check=False)
        if set_img.returncode != 0:
            return {"ok": False, "error": (set_img.stderr or "kubectl set image failed")[:300]}
        al.kc("-n", "petstore-prod", "rollout", "status", "deploy/petstore", "--timeout=60s", check=False)
        if issue:
            _gh("issue", "comment", str(issue["number"]), "--repo", REPO,
                "--body", f"Approved and promoted to prod at image tag `{tag}`: {prod_url()}")
            _gh("issue", "close", str(issue["number"]), "--repo", REPO)
        state["stage"] = "promoted"
        _save_state(state)
        return {"ok": True, "tag": tag, "issue": issue}
    reason = (reason or "").strip()
    if not reason:
        return {"ok": False, "error": "a reason is required to deny"}
    if issue:
        body = (f"Denied in staging review: {reason}\n\nBack to agent-ready for another pass -- "
                f"dev-bot should read this comment and revise accordingly.")
        _gh("issue", "comment", str(issue["number"]), "--repo", REPO, "--body", body)
        _gh("issue", "edit", str(issue["number"]), "--repo", REPO,
            "--remove-label", "in-review", "--add-label", "agent-ready")
    state["stage"] = "denied"
    _save_state(state)
    return {"ok": True, "denied": True, "issue": issue}
