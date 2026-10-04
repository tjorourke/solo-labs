#!/usr/bin/env python3
"""Run with python3 test_render.py. Node.js is required for browser-core parity."""
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml
import render

HERE = Path(__file__).resolve().parent


def catalogue():
    return render.parse_yaml((HERE / "example.yaml").read_text())[0]


def mutate(path, value):
    doc = catalogue()
    target = doc
    for key in path[:-1]:
        target = target[key]
    target[path[-1]] = value
    return doc


def browser_results(cases):
    script = """const fs=require('node:fs'), core=require(process.argv[1]);
const cases=JSON.parse(fs.readFileSync(0,'utf8'));
process.stdout.write(JSON.stringify(cases.map(d=>{try{return {output:core.render(core.compile(d))}}catch(e){return {error:e.message}}})));"""
    result = subprocess.run(["node", "-e", script, str(HERE / "core.js")],
                            input=json.dumps(cases), text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


class RendererTests(unittest.TestCase):
    def test_backend_isolation_and_deny(self):
        compiled = render.compile_catalogue([catalogue()])
        policies = {p["server"]: p for p in compiled["policies"]}
        self.assertEqual(policies["restricted"]["expressions"], ["false"])
        self.assertEqual(len(policies["github"]["rows"]), 1)
        self.assertNotIn("read_invoices", "\n".join(policies["github"]["expressions"]))
        self.assertNotIn("create_pull_request", "\n".join(policies["github"]["expressions"]))
        delegated = next(r for r in policies["finance"]["rows"] if r["grant"]["name"] == "finance-delegated")
        expr = render.expression(delegated["grant"], delegated["tools"])
        self.assertIn("has(jwt.act.sub)", expr)
        self.assertIn("type(jwt.groups) == list", expr)
        self.assertIn("type(jwt.agent_roles) == list", expr)
        self.assertNotIn("||", expr)
        docs = list(yaml.safe_load_all(render.render(compiled)))
        self.assertEqual(len(docs), 4)
        self.assertTrue(all(d["kind"] == "AgentgatewayPolicy" for d in docs))

    def test_no_grants_and_empty_sets_deny(self):
        for doc in [mutate(["grants"], []), mutate(["servers", "github", "toolSets", "reader"], [])]:
            policies = {p["server"]: p for p in render.compile_catalogue([doc])["policies"]}
            self.assertEqual(policies["github"]["expressions"], ["false"])

    def test_stable_merging(self):
        doc = catalogue()
        original = render.render(render.compile_catalogue([doc]))
        doc["servers"] = dict(reversed(list(doc["servers"].items())))
        doc["grants"].reverse()
        for grant in doc["grants"]:
            grant["access"].reverse()
        split = [{"version": "1", "grants": doc["grants"]}, {"version": "1", "servers": doc["servers"]}]
        self.assertEqual(original, render.render(render.compile_catalogue(split)))

    def test_overlapping_sets_deduplicate(self):
        doc = catalogue()
        doc["servers"]["github"]["toolSets"]["extra"] = ["list_issues", "new_tool"]
        doc["grants"][1]["access"].append("github/extra")
        policy = next(p for p in render.compile_catalogue([doc])["policies"] if p["server"] == "github")
        self.assertEqual(policy["rows"][0]["tools"].count("list_issues"), 1)
        self.assertIn("new_tool", policy["rows"][0]["tools"])

    def test_yaml_rejects_ambiguous_inputs(self):
        for source in ["version: 1\nversion: 1", "version: &v 1", "version: *v", "version: !!str 1", "", "---\n", "version: 1\n---\n", "[broken"]:
            with self.subTest(source=source), self.assertRaises(render.CatalogueError):
                render.parse_yaml(source)
        with self.assertRaises(render.CatalogueError):
            render.parse_yaml("x" * (render.MAX_BYTES + 1))

    def test_invalid_catalogues_and_browser_parity(self):
        invalid = [
            mutate(["version"], "2"), mutate(["servers"], []), mutate(["grants"], {}),
            mutate(["grants", 0, "groups"], "employees"), mutate(["grants", 0, "groups"], []),
            mutate(["grants", 0, "groups"], ["x", "x"]), mutate(["grants", 0, "access"], ["missing/read"]),
            mutate(["grants", 0, "access"], ["github/missing"]), mutate(["grants", 0, "access"], []),
            mutate(["grants", 0, "roles"], ["role"]), mutate(["grants", 0, "agentRoles"], []),
            mutate(["grants", 0, "typo"], "x"), mutate(["grants", 0, "name"], "Bad ID"),
            mutate(["servers", "github", "namespace"], "bad/namespace"),
            mutate(["servers", "github", "backend"], "UPPER"),
            mutate(["servers", "github", "backend"], "corporate-mcp"),
            mutate(["servers", "github", "toolSets", "reader"], ["*"]),
            mutate(["servers", "github", "toolSets", "reader"], ["bad\nname"]),
            mutate(["servers", "github", "toolSets", "reader"], ["x", "x"]),
            mutate(["servers", "github", "toolSets", "reader"], "not-a-list"),
            mutate(["servers", "github", "toolSets"], []),
            mutate(["servers", "github", "unknown"], "x"),
            {"version": "1"}, {"version": "1", "servers": {}, "unknown": "x"},
        ]
        cases = [[d] for d in invalid] + [[catalogue(), catalogue()]]
        results = browser_results(cases)
        for docs, js in zip(cases, results):
            with self.subTest(doc=docs):
                with self.assertRaises(render.CatalogueError) as error:
                    render.compile_catalogue(docs)
                self.assertEqual(js.get("error"), str(error.exception))

    def test_valid_browser_parity_and_escaping(self):
        unusual = catalogue()
        unusual["servers"]["github"]["toolSets"]["reader"] = ['a" || true || "', "back\\slash", "café", "😀", "\ue000", "</script>"]
        unusual["grants"][1]["groups"] = ['engineering"ops', "开发"]
        empty = mutate(["grants"], [])
        all_profiles = catalogue()
        all_profiles["grants"][0]["groups"] = ["employees", "contractors"]
        cases = [[catalogue()], [unusual], [empty], [all_profiles]]
        for docs, js in zip(cases, browser_results(cases)):
            expected = render.render(render.compile_catalogue(docs))
            self.assertEqual(js.get("output"), expected)
        expression = render.compile_catalogue([unusual])["policies"][2]["expressions"][0]
        self.assertIn('\\"', expression)

    def test_fifty_servers_fifty_tools(self):
        doc = {"version": "1", "servers": {}, "grants": []}
        for i in range(50):
            name = f"server-{i:02}"
            doc["servers"][name] = {"namespace": "tools", "backend": name,
                                     "toolSets": {"reader": [f"tool_{j:03}" for j in range(50)]}}
            doc["grants"].append({"name": f"grant-{i:02}", "groups": [f"team-{i}"], "access": [name + "/reader"]})
        compiled = render.compile_catalogue([doc])
        self.assertEqual(len(compiled["policies"]), 50)
        self.assertTrue(all(len(p["rows"]) == 1 and len(p["rows"][0]["tools"]) == 50 for p in compiled["policies"]))
        self.assertEqual(browser_results([[doc]])[0]["output"], render.render(compiled))

    def test_cli_atomic_output_check_and_stdin(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "policies.yaml"
            out.write_text("keep me")
            bad = Path(directory) / "bad.yaml"
            bad.write_text("version: 1\nunknown: typo")
            cmd = [sys.executable, str(HERE / "render.py")]
            result = subprocess.run(cmd + [str(bad), "-o", str(out)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(out.read_text(), "keep me")
            result = subprocess.run(cmd + [str(HERE / "example.yaml"), "--check", "-o", str(out)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertEqual(out.read_text(), "keep me")
            result = subprocess.run(cmd + ["-"], input=(HERE / "example.yaml").read_text(), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, render.render(render.compile_catalogue([catalogue()])))

    def test_https_source_and_redirect_rules(self):
        for url in ["http://example.com/access.yaml", "https://user:pass@example.com/access.yaml", "file:///tmp/access.yaml"]:
            with self.subTest(url=url), self.assertRaises(render.CatalogueError):
                render.check_url(url)
        with self.assertRaises(render.CatalogueError):
            render.HTTPSRedirect().redirect_request(None, None, 302, "", {}, "http://example.com")
        opener = mock.Mock()
        opener.open.return_value = io.BytesIO(b"version: 1")
        with mock.patch("render.urllib.request.build_opener", return_value=opener):
            self.assertEqual(render.read_source("https://example.com/access.yaml"), "version: 1")
        opener.open.return_value = io.BytesIO(b"x" * (render.MAX_BYTES + 1))
        with mock.patch("render.urllib.request.build_opener", return_value=opener), self.assertRaises(render.CatalogueError):
            render.read_source("https://example.com/access.yaml")


if __name__ == "__main__":
    unittest.main()
