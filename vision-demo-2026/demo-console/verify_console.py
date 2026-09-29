#!/usr/bin/env python3
"""Run labs through the running console's HTTP API, exactly as the browser does.

verify_labs.py runs the actions in-process. This drives http://localhost:8900
instead: it reads each chapter page for the action revisions and checks, posts
/api/notebook/run, evaluates the checks on the streamed output, and resets with
/api/labs/reset. What passes here passes for a presenter clicking Run.

Usage: python3 verify_console.py [--only demo-4 --only demo-11] [--no-reset-after]
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import html
import json
from pathlib import Path
import re
import sys
import urllib.request

import notebooks
from verify_labs import evaluate

BASE = "http://localhost:8900"
CMD = re.compile(r'<div class="pr-cmd" data-demo="[^"]+" data-step="[^"]+" data-index="(\d+)" '
                 r'data-part="(\d+)" data-revision="([0-9a-f]+)" data-checks="([^"]*)"[^>]*>\s*'
                 r'<button[^>]*>\s*<span class="pr-cmd-n">\d+</span>\s*<span class="pr-cmd-title">([^<]*)</span>')


def stream(path, body):
    req = urllib.request.Request(BASE + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=3600) as r:
        for line in r:
            if line.strip():
                yield json.loads(line)


def reset(lab):
    events = list(stream("/api/labs/reset", {"lab": lab}))
    ok = any(e.get("type") == "done" and e.get("code") == 0 for e in events)
    if not ok:
        print("\n".join(e.get("text", "") for e in events if e.get("text"))[-3000:])
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--only", action="append", choices=list(notebooks.DEMOS))
    ap.add_argument("--no-reset-after", action="store_true")
    a = ap.parse_args()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder = notebooks.ROOT / "data" / "lab-runs" / f"console-{stamp}"
    folder.mkdir(parents=True, exist_ok=True)
    summary, failed = {}, False
    for lab in a.only or notebooks.DEMOS:
        passed = total = 0
        print(f"### {lab}: reset before", flush=True)
        if not reset(lab):
            print(f"  FAIL: reset before", flush=True)
            summary[lab] = "reset before failed"
            failed = True
            continue
        stopped = None
        for chapter in notebooks.load(lab).story:
            page = urllib.request.urlopen(f"{BASE}/{lab}/{chapter.id}").read().decode()
            for n, (index, part, rev, checks, title) in enumerate(CMD.findall(page), 1):
                total += 1
                text, code = [], -1
                for ev in stream("/api/notebook/run", {"demo": lab, "step": chapter.id, "index": int(index),
                                                       "part": int(part), "revision": rev}):
                    if ev["type"] in ("out", "error"):
                        text.append(ev.get("text", ""))
                    if ev["type"] == "error":
                        code = -1
                    if ev["type"] == "done":
                        code = ev["code"]
                out = "\n".join(text)
                (folder / f"{lab}-{chapter.id}-{n}.txt").write_text(out + "\n")
                rows = evaluate(json.loads(html.unescape(checks)), out, code)
                ok = all(r["state"] == "ok" for r in rows)
                print(f"  {'PASS' if ok else 'FAIL'} {chapter.id}.{n} {html.unescape(title)}: "
                      + ", ".join(f"{r['label']}={r['state']}" for r in rows if r["state"] != "ok" or not ok), flush=True)
                if not ok:
                    print(out[-2500:], flush=True)
                    stopped = f"{chapter.id}.{n}"
                    break
                passed += 1
            if stopped:
                break
        after = True if a.no_reset_after else reset(lab)
        summary[lab] = f"{passed}/{total} actions{'' if not stopped else ', stopped at ' + stopped}, reset after {'ok' if after else 'FAILED'}"
        failed |= bool(stopped) or not after
        print(f"### {lab}: {summary[lab]}", flush=True)
    (folder / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
