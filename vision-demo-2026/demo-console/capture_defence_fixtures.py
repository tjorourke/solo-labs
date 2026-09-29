"""Capture demo-13 fixtures from a complete, passing verify_console run."""
import argparse
import json
from pathlib import Path
import re

import notebooks
import present
from verify_labs import evaluate


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("run", type=Path, help="data/lab-runs/console-<timestamp>")
    args = ap.parse_args()
    summary = json.loads((args.run / "summary.json").read_text())["demo-13"]
    demo = notebooks.load("demo-13")
    count = sum(len(present.actions(demo, chapter)) for chapter in demo.story)
    if summary != f"{count}/{count} actions, reset after ok":
        raise SystemExit("Not a complete passing run: " + summary)
    captured = {}
    for chapter in demo.story:
        for n, action in enumerate(present.actions(demo, chapter), 1):
            text = (args.run / f"demo-13-{chapter.id}-{n}.txt").read_text()
            text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
            text = re.sub(r"/Users/[^\s\"']+", "<local-path>", text)
            text = re.sub(r"/(?:private/)?var/folders/[^\s\"']+", "<local-path>", text)
            text = "\n".join(line.rstrip() for line in text.splitlines()) + "\n"
            rows = evaluate(action["checks"], text, 0)
            if any(row["state"] != "ok" for row in rows):
                raise SystemExit(f"Fixture checks failed: {chapter.id}.{n}: {rows}")
            captured[f"{chapter.id}_{action['index']}.txt"] = text
    out = notebooks.ROOT / "present/fixtures/demo-13"
    out.mkdir(exist_ok=True)
    for name, text in captured.items():
        (out / name).write_text(text.rstrip() + "\n")
    print(f"Captured {len(captured)} checked fixtures from {args.run.name}")


if __name__ == "__main__":
    main()
