#!/usr/bin/env python3
"""Run the same guided actions as the browser, record checks, then reset.

Usage: python3 verify_labs.py --only demo-1
No cloud provisioning. Uses the installed local lab platform and credentials.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

import lab_reset
import notebooks
import present


def evaluate(checks, text, code):
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    rows = []
    for c in checks:
        t, found = text, True
        if c.get("from"):
            i = t.find(c["from"])
            found = i >= 0
            t = t[i + len(c["from"]):] if found else ""
        if c.get("to"):
            i = t.find(c["to"])
            found = found and i >= 0
            t = t[:i] if i >= 0 else ""
        hit = bool(re.search(c["match"], t, re.M))
        passed = found and (not hit if c.get("absent") else hit)
        rows.append({"label": c["label"], "state": "ok" if passed else "warn" if c.get("warn") else "bad"})
    if not rows or code != 0:
        rows.append({"label": f"Exit status {code}", "state": "ok" if code == 0 else "bad"})
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", choices=list(notebooks.DEMOS), action="append")
    parser.add_argument("--from-chapter", help="Resume an existing run; use with --no-reset-before.")
    parser.add_argument("--from-action", type=int, default=1, help="First action in the resumed chapter, numbered from 1.")
    parser.add_argument("--no-reset-before", action="store_true")
    parser.add_argument("--no-reset-after", action="store_true", help="Keep resources temporarily for investigation.")
    parser.add_argument("--output", type=Path, default=notebooks.ROOT / "data" / "lab-runs")
    args = parser.parse_args()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder = args.output / stamp
    folder.mkdir(parents=True, exist_ok=True)
    report = {"started": stamp, "actions": [], "resets": []}
    failed = False

    def record():
        (folder / "results.json").write_text(json.dumps(report, indent=2) + "\n")

    def reset(lab, phase):
        events = []
        lab_reset.run(lab, events.append)
        ok = any(e.get("type") == "done" and e.get("code") == 0 for e in events)
        report["resets"].append({"lab": lab, "phase": phase, "passed": ok})
        (folder / f"{lab}-reset-{phase}.json").write_text(json.dumps(events, indent=2) + "\n")
        record()
        print(f"{lab} reset {phase}: {'PASS' if ok else 'FAIL'}", flush=True)
        if not ok:
            print("\n".join(e.get("text", "") for e in events), flush=True)
        return ok

    for lab in args.only or notebooks.DEMOS:
        try:
            if not args.no_reset_before and not reset(lab, "before"):
                failed = True
                continue
            demo = notebooks.load(lab)
            start = next((i for i, s in enumerate(demo.story) if s.id == args.from_chapter), 0)
            for chapter_no, chapter in enumerate(demo.story[start:]):
                for i, action in enumerate(present.actions(demo, chapter), 1):
                    if chapter_no == 0 and i < args.from_action:
                        continue
                    print(f"{lab}/{chapter.id} step {i}: {action['title']}", flush=True)
                    events = []
                    notebooks.run(lab, chapter.id, action["index"], events.append, part=action["part"], revision=action["revision"])
                    code = next((e["code"] for e in events if e["type"] == "done"), -1)
                    text = "\n".join(e.get("text", "") for e in events if e["type"] in ("out", "error"))
                    if any(e["type"] == "error" for e in events):
                        code = -1
                    rows = evaluate(action["checks"], text, code)
                    ok = all(r["state"] == "ok" for r in rows)
                    name = f"{lab}-{chapter.id}-{i}"
                    (folder / f"{name}.txt").write_text(text + "\n")
                    report["actions"].append({"lab": lab, "chapter": chapter.id, "action": i, "title": action["title"], "revision": action["revision"], "code": code, "checks": rows, "passed": ok})
                    record()
                    print("  " + ("PASS" if ok else "FAIL") + ": " + ", ".join(r["label"] for r in rows), flush=True)
                    if not ok:
                        print(text, flush=True)
                        raise RuntimeError(f"Stopped at {name}")
        except Exception as e:
            failed = True
            print(str(e), file=sys.stderr, flush=True)
        finally:
            if not args.no_reset_after and not reset(lab, "after"):
                failed = True
    report["passed"] = not failed
    report["finished"] = datetime.now(timezone.utc).isoformat()
    record()
    print(f"Results: {folder}", flush=True)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
