#!/usr/bin/env python3
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MCP = json.loads((ROOT / "data" / "mcp-demo.json").read_text())


def mode_totals(mode):
    steps = [s for s in mode["steps"] if not s.get("internal")]
    tin = sum(s["tokens_in"] for s in steps)
    tout = sum(s["tokens_out"] for s in steps)
    usd = tin * MCP["rates"]["input_per_m"] / 1e6 + tout * MCP["rates"]["output_per_m"] / 1e6
    loops = sum(1 for s in steps if s["kind"] != "tools/list")
    return tin, tout, usd, loops


class McpTests(unittest.TestCase):
    def test_code_mode_is_cheaper_faster_and_fewer_loops(self):
        a = mode_totals(MCP["modes"]["standard"])
        b = mode_totals(MCP["modes"]["code"])
        self.assertGreater(a[3], b[3])
        self.assertGreater(a[2], b[2] * 10)
        self.assertEqual(MCP["modes"]["standard"]["tools_visible"], 94)
        self.assertEqual(MCP["modes"]["code"]["tools_visible"], 2)
        self.assertEqual(MCP["modes"]["code"]["visible_tools"], ["get_tool", "run_code"])
        self.assertEqual(MCP["report"]["open"], 24)
        self.assertEqual(sum(len(g["items"]) for g in MCP["report"]["groups"]), 24)

    def test_same_question(self):
        self.assertIn("tjorourke/network-slice-manager", MCP["prompt"])
        self.assertTrue(all(it.get("url", "").startswith("https://github.com/") for g in MCP["report"]["groups"] for it in g["items"]))


class MyAgentsTests(unittest.TestCase):
    def test_yaml_goes_through_the_registry(self):
        from agents_lab import render_yaml
        y = render_yaml({
            "name": "copilot",
            "prompt": "Be brief.",
            "skills": ["incident-triage"],
            "mcp": [{"id": "github", "tools": ["list_pull_requests"]}],
        })
        self.assertIn("apiVersion: ar.dev/v1alpha1", y)
        self.assertIn("kind: Agent", y)
        self.assertIn("kind: Deployment", y)
        self.assertIn("kind: Prompt", y)
        self.assertIn("kind: Skill", y)
        self.assertIn("source:", y)
        self.assertIn("repository:", y)
        self.assertNotIn("inline:", y)
        self.assertIn("kind-kagent", y)
        self.assertIn("list_pull_requests", y)
        # The agent references the MCPServer; the platform publishes it. Re-publishing it
        # from here would wipe its labels, and with them its approval tier.
        self.assertIn("mcpServers:\n  - kind: MCPServer\n    name: github", y)
        self.assertNotIn("\nkind: MCPServer", y)
        self.assertIn("tag: v1", y)
        self.assertNotIn("kagent.dev", y)
        self.assertNotIn("merge_pull_request", y)

    def test_github_policy_allows_prefixed_and_plain_names(self):
        from agents_lab import _tool_aliases, _policy_yaml
        aliases = _tool_aliases(["list_issues", "list_pull_requests"])
        self.assertIn("list_issues", aliases)
        self.assertIn("github_list_issues", aliases)
        self.assertIn("list_pull_requests", aliases)
        self.assertIn("github_list_pull_requests", aliases)
        y = _policy_yaml([("my-agent2", aliases)], name="my-agent2")
        self.assertIn('source.identity.serviceAccount == "my-agent2"', y)
        self.assertIn('"list_issues"', y)
        self.assertIn('"github_list_issues"', y)
        self.assertIn("EnterpriseAgentgatewayPolicy", y)

    def test_no_label_means_an_admin_approves(self):
        import agents_lab
        labels = {"github": {}, "site-daylight": {agents_lab.AUTO_APPROVE_LABEL: "true"},
                  "telco-inventory": {agents_lab.AUTO_APPROVE_LABEL: "yes"}}
        self.assertFalse(agents_lab.mcp_auto_approve("github", labels))
        self.assertTrue(agents_lab.mcp_auto_approve("daylight", labels))
        # Only the literal "true" counts. Anything else is treated as no label.
        self.assertFalse(agents_lab.mcp_auto_approve("telco", labels))
        self.assertFalse(agents_lab.mcp_auto_approve("k8s", labels))

    def test_auto_approved_server_is_granted_without_an_admin(self):
        from unittest import mock
        import agents_lab
        labels = {"site-daylight": {agents_lab.AUTO_APPROVE_LABEL: "true"}}
        store = {"agents": [
            {"name": "climber", "mcp": [{"id": "daylight", "tools": ["work_window"]}]},
            {"name": "mixed", "mcp": [{"id": "daylight", "tools": ["daylight"]},
                                      {"id": "github", "tools": ["list_issues"]}]},
        ]}
        with mock.patch.object(agents_lab, "load_store", return_value=store), \
             mock.patch.object(agents_lab, "registry_mcp_labels", return_value=labels):
            day = dict(agents_lab._grants("daylight", labels))
            self.assertIn("climber", day)
            self.assertIn("mixed", day)
            self.assertIn("site_daylight_work_window", day["climber"])
            # GitHub has no label: nobody is on it until an admin approves.
            self.assertEqual(agents_lab._grants("github", labels), [])
            self.assertTrue(agents_lab.mcp_is_approved(store["agents"][0]))
            self.assertFalse(agents_lab.mcp_is_approved(store["agents"][1]))
            self.assertEqual(agents_lab.mcp_tiers(store["agents"][1]),
                             {"auto": ["daylight"], "restricted": ["github"]})
            y = agents_lab._policy_yaml(agents_lab._grants("daylight", labels), sid="daylight")
            self.assertIn("name: daylight-per-agent", y)
            self.assertIn("name: daylight-mcp", y)
            self.assertIn('source.identity.serviceAccount == "climber"', y)

    def test_github_policy_pins_the_namespace(self):
        from agents_lab import _policy_yaml
        y = _policy_yaml([("a", ["list_issues"]), ("b", ["search_code"])])
        self.assertEqual(y.count('source.identity.namespace == "kagent"'), 2)
        self.assertIn('source.identity.serviceAccount == "b"', y)

    def test_probe_reads_an_empty_result_as_allowed(self):
        import json
        from unittest import mock
        import agents_lab

        def run(body, http=200):
            out = mock.Mock(stdout=json.dumps({"http": http, "body": body}) + "\n", stderr="")
            with mock.patch.object(agents_lab.subprocess, "run", return_value=out):
                return agents_lab._probe_github("tom2-agent")

        ok = run('event: message\ndata: {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\\"issues\\":[],\\"pageInfo\\":{\\"hasNextPage\\":false}}"}]}}\n\n')
        self.assertTrue(ok["allowed"])
        no = run('{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Unknown tool: list_issues"}}', 400)
        self.assertFalse(no["allowed"])
        self.assertIn("Unknown tool", no["detail"])
        err = run('data: {"jsonrpc":"2.0","id":2,"result":{"isError":true,"content":[{"type":"text","text":"repo not found"}]}}')
        self.assertFalse(err["allowed"])

    def test_edit_bumps_the_registry_tag(self):
        from agents_lab import render_yaml
        y = render_yaml({
            "name": "copilot",
            "version": "v3",
            "prompt": "Be briefer.",
            "skills": [],
            "mcp": [{"id": "github", "tools": ["list_pull_requests"]}],
        })
        self.assertIn("tag: v3", y)
        self.assertGreaterEqual(y.count("tag: v3"), 2)

    def test_authored_skill_points_at_where_it_was_written(self):
        """A Skill has no inline body, so the subfolder is the whole contract. If the
        package lands somewhere the yaml does not name, the registry resolves nothing."""
        import tempfile
        import yaml as pyyaml
        import agents_lab
        with tempfile.TemporaryDirectory() as tmp:
            old = agents_lab.SKILL_PACKAGES
            agents_lab.SKILL_PACKAGES = Path(tmp)
            try:
                d = agents_lab.write_skill_package(
                    "slice-health", "Slice health", 'Read "KPIs" and call a breach',
                    "# Slice health\n\nLatency first.\n")
            finally:
                agents_lab.SKILL_PACKAGES = old
            doc = pyyaml.safe_load((d / "skill.yaml").read_text())
            self.assertEqual(doc["apiVersion"], "ar.dev/v1alpha1")
            self.assertEqual(doc["kind"], "Skill")
            self.assertEqual(doc["metadata"]["name"], "slice-health")
            self.assertEqual(doc["spec"]["description"], 'Read "KPIs" and call a breach')
            repo = doc["spec"]["source"]["repository"]
            self.assertEqual(repo["subfolder"], f"{agents_lab.SKILL_SUBFOLDER}/slice-health")
            self.assertEqual(repo["subfolder"].rsplit("/", 1)[-1], d.name)
            self.assertIn("Latency first.", (d / "SKILL.md").read_text())

    def test_only_the_first_skill_survives(self):
        """The picker is single-select; the server says so too. Handed two, it reads the
        first and never the second, so an unknown first id is what comes back."""
        from agents_lab import create_agent
        r = create_agent({
            "name": "clamp-test",
            "prompt": "Be brief.",
            "skills": ["not-a-real-skill", "github-briefing"],
        })
        self.assertFalse(r["ok"])
        self.assertIn("not-a-real-skill", r["error"])

    def test_agent_prompts_sort_below_standalone_ones(self):
        from agents_lab import sort_prompts
        rows = sort_prompts([
            {"id": "demo-agent-prompt", "generated": True, "updated": "2026-09-22T10:00:00Z"},
            {"id": "incident-brief", "generated": False, "updated": "2026-09-01T10:00:00Z"},
            {"id": "slice-review", "generated": False, "updated": "2026-09-10T10:00:00Z"},
        ])
        self.assertEqual([p["id"] for p in rows],
                         ["slice-review", "incident-brief", "demo-agent-prompt"])


if __name__ == "__main__":
    unittest.main()


class NotebookDemoTests(unittest.TestCase):
    """The demo pages are generated from the notebook, so a notebook edit that
    breaks the split shows up here rather than in front of a customer."""

    def setUp(self):
        import notebooks
        self.notebooks = notebooks
        self.demo = notebooks.load("demo-1")

    def test_every_numbered_section_became_a_step(self):
        nums = [s.num for s in self.demo.steps if s.num]
        self.assertEqual(nums, [f"1.{i}" for i in range(1, 10)])
        self.assertIn("connect", [s.id for s in self.demo.steps])
        self.assertIn("reset", [s.id for s in self.demo.steps])

    def test_steps_carry_the_cells_they_should_run(self):
        # 1.4 publishes the global hostname over three cells; 1.9 is read-only.
        self.assertEqual(self.demo.step("1.4").code_blocks, 3)
        self.assertEqual(self.demo.step("1.9").code_blocks, 0)
        self.assertIn("kubectl", self.demo.step("1.1").blocks[-1].source)

    def test_a_fenced_hash_comment_does_not_start_a_step(self):
        # 1.2's trailing markdown shows bash comments in a fence. Those lines
        # start with '#', and once split a step out of the middle of the demo.
        self.assertNotIn("apply to mesh1", [s.title for s in self.demo.steps])

    def test_blurbs_are_whole_sentences(self):
        for s in self.demo.steps:
            self.assertTrue(s.blurb, f"{s.id} has no blurb")
            self.assertLessEqual(len(s.blurb), 200, f"{s.id} blurb is too long")
            self.assertEqual(s.blurb.count("("), s.blurb.count(")"), f"{s.id} blurb brackets")

    def test_every_demo_splits_into_a_story(self):
        for demo_id in self.notebooks.DEMOS:
            demo = self.notebooks.load(demo_id)
            self.assertTrue(demo.story, f"{demo_id} has no story steps")
            self.assertTrue(demo.intro_html or demo_id == "demo-7", demo_id)
            for step in demo.steps:
                self.assertTrue(step.title, f"{demo_id} has an untitled step")

    def test_every_presentation_rule_still_matches(self):
        """The rules rewrite exact sentences. A notebook edit that changes one
        must fail here, not leak a script name onto the page."""
        for demo_id, rules in self.notebooks.PRESENT.items():
            fired = self.notebooks.load(demo_id).rules_fired
            missed = [rules[i][0][:60] for i in range(len(rules)) if i not in fired]
            self.assertEqual(missed, [], f"{demo_id}: rules no longer match")

    def test_no_page_tells_the_presenter_to_run_a_script(self):
        import html as H
        import re
        pat = re.compile(r"[\w./-]*\.sh\b|demo-scripts|Jupyter|Kernel", re.I)

        def prose(markup):
            text = re.sub(r"<svg\b.*?</svg>", " ", markup, flags=re.S)
            return H.unescape(re.sub(r"<[^>]+>", " ", text))

        for demo_id in self.notebooks.DEMOS:
            demo = self.notebooks.load(demo_id)
            found = pat.findall(prose(demo.intro_html))
            for step in demo.steps:
                for b in step.blocks:
                    if b.kind == "md":
                        found += pat.findall(prose(b.html))
            self.assertEqual(found, [], f"{demo_id} prose still names a script")

    def test_the_intro_drops_the_jupyter_only_bits(self):
        self.assertNotIn("Jupyter Kernel", self.demo.intro_html)
        self.assertIn("<svg", self.demo.intro_html)

    def test_pages_render(self):
        for demo_id in self.notebooks.DEMOS:
            demo = self.notebooks.load(demo_id)
            page = self.notebooks.demo_page(demo)
            self.assertIn(demo.title, page)
            for step in demo.story:
                self.assertIn(f"/{demo_id}/{step.id}", page)
                self.notebooks.step_page(demo, step)
        self.assertIn("Ambient multicluster failover", self.notebooks.demo_page(self.demo))
        step = self.notebooks.step_page(self.demo, self.demo.step("1.5"))
        self.assertIn("nb-run", step)
        # 1.1 embeds a heredoc; it has to reach the page escaped, not as markup.
        first = self.notebooks.step_page(self.demo, self.demo.step("1.1"))
        self.assertIn("&lt;&lt;&#x27;EOF&#x27;", first)
        self.assertNotIn("<<'EOF'", first)

    def test_markdown_renders_what_the_notebooks_use(self):
        md = self.notebooks.render_markdown
        self.assertIn("<strong>x</strong>", md("**x**"))
        self.assertIn("<code>y</code>", md("`y`"))
        self.assertIn('<a href="http://z"', md("[z](http://z)"))
        self.assertIn("<li>a</li>", md("- a"))
        self.assertIn("nb-table", md("| a | b |\n|---|---|\n| 1 | 2 |"))
        self.assertIn("&lt;script&gt;", md("a <script> in prose"))
