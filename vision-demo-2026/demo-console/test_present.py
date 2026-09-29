#!/usr/bin/env python3
"""The presenter spec has to line up with the notebook it drives.

Every story step needs an entry, one block per code cell, and every check has to
pass against real output from a live run (present/fixtures/). The evaluation
below mirrors evaluate() in static/js/present.js.
"""
import re
import subprocess
import unittest
from unittest.mock import patch
from html.parser import HTMLParser

import notebooks
import present

FIXTURES = notebooks.ROOT / "present" / "fixtures"


def scope(text, c):
    if c.get("from"):
        i = text.find(c["from"])
        text = "" if i < 0 else text[i + len(c["from"]):]
    if c.get("to"):
        j = text.find(c["to"])
        if j >= 0:
            text = text[:j]
    return text


def verdict(c, text):
    t = scope(text, c)
    hit = re.search(c["match"], t, re.M) is not None
    ok = not hit if c.get("absent") else hit
    value = ""
    if c.get("value"):
        m = re.search(c["value"], t, re.M)
        if m:
            value = (m.group(1) if m.groups() else m.group(0)).strip()
    return ok, value


class Balance(HTMLParser):
    """Only div/section/details/aside: a stray close on those moves the stage."""
    TAGS = {"div", "section", "details", "aside"}

    def __init__(self):
        super().__init__()
        self.stack, self.bad = [], []

    def handle_starttag(self, tag, attrs):
        if tag in self.TAGS:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag in self.TAGS:
            if self.stack and self.stack[-1] == tag:
                self.stack.pop()
            else:
                self.bad.append(tag)


class PresentSpecTests(unittest.TestCase):
    def specs(self):
        for path in sorted(present.PRESENT_DIR.glob("*.json")):
            yield notebooks.load(path.stem), present.spec(path.stem)

    def test_every_story_step_has_one_block_per_cell(self):
        for demo, s in self.specs():
            for step in demo.story:
                with self.subTest(demo=demo.id, step=step.id):
                    self.assertIn(step.id, s["steps"])
                    code = [b for b in step.blocks if b.kind == "code"]
                    self.assertEqual(len(s["steps"][step.id].get("blocks") or []), len(code))

    def test_checks_pass_on_a_real_run(self):
        for demo, s in self.specs():
            for step_id, st in s["steps"].items():
                for i, b in enumerate(st.get("blocks") or []):
                    fx = FIXTURES / demo.id / f"{step_id}_{i}.txt"
                    if not fx.is_file():
                        continue
                    text = fx.read_text()
                    for c in b.get("checks") or []:
                        with self.subTest(step=step_id, block=i, check=c["label"]):
                            ok, value = verdict(c, text)
                            if not c.get("warn"):
                                self.assertTrue(ok, c)
                            if c.get("save"):
                                self.assertTrue(value.startswith("http"), value)

    def test_step_pages_render(self):
        for demo, s in self.specs():
            for step in demo.story:
                with self.subTest(step=step.id):
                    out = present.view(demo, step)
                    self.assertIn('class="pr"', out)
                    self.assertEqual(out.count('class="pr-cmd"'), len(present.actions(demo, step)))
                    p = Balance()
                    p.feed(out)
                    self.assertEqual((p.bad, p.stack), ([], []))

    def test_splits_keep_every_command_and_are_valid_shell(self):
        for demo, _ in self.specs():
            for step in demo.story:
                actions = present.actions(demo, step)
                for index, cell in enumerate(b for b in step.blocks if b.kind == "code"):
                    pieces = [a for a in actions if a["index"] == index]
                    # Removing blank lines accounts for trimming at boundaries;
                    # every actual command, heredoc and comment must survive.
                    normalise = lambda s: [l.rstrip() for l in s.splitlines() if l.strip()]
                    self.assertEqual(normalise("\n".join(a["source"] for a in pieces)), normalise(cell.source))
                for action in actions:
                    with self.subTest(demo=demo.id, step=step.id, action=action["title"]):
                        checked = subprocess.run(["bash", "-n"], input=notebooks.preamble(demo.id) + "\n" + action["script"], text=True, capture_output=True)
                        self.assertEqual(checked.returncode, 0, checked.stderr)
                        self.assertTrue(action["instruction"])
                        self.assertTrue(action["expect"])

    def test_stale_action_cannot_execute(self):
        demo = notebooks.load("demo-1")
        with patch("notebooks.subprocess.Popen") as popen:
            with self.assertRaisesRegex(ValueError, "Reload"):
                notebooks.run(demo.id, "1.1", 0, lambda e: None, part=0, revision="old")
            popen.assert_not_called()

    def test_an_action_stops_at_a_failed_command(self):
        events = []
        notebooks.execute("test", "set -eo pipefail\nfalse\nprintf 'must not run'", events.append, "test")
        self.assertEqual(events[-1], {"type": "done", "code": 1})
        self.assertFalse(any(e.get("text") == "must not run" for e in events))

    def test_reset_cannot_overlap_a_lab_run(self):
        with notebooks._execution_lock:
            events = []
            notebooks.execute("test", "true", events.append, "test")
            self.assertEqual(events[0]["type"], "error")
            self.assertIn("Another lab", events[0]["text"])

    def test_reset_is_scoped_and_checks_deletion(self):
        import lab_reset
        for lab in lab_reset.SCOPES:
            script = lab_reset.reset_script(lab)
            result = subprocess.run(["bash", "-n"], input=script, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Still present", script)
            self.assertNotIn("--all", script)
            self.assertNotIn("delete cluster", script)
        model = lab_reset.reset_script("demo-7")
        for preserved in ("agentdesktop", "github-mcp", "agentregistry", "ai-gateway-tracing"):
            self.assertNotIn(preserved, model)
        self.assertNotIn("bookinfo", lab_reset.reset_script("demo-3"))
        mesh = lab_reset.reset_script("demo-1")
        self.assertLess(mesh.rfind("delete namespace bookinfo"), mesh.find("delete serviceentry"))
        with self.assertRaises(ValueError):
            lab_reset.reset_script("not-a-lab")


if __name__ == "__main__":
    unittest.main()
