"""Evidence must not count unrelated traffic or turn a read failure into success."""
import json
import unittest
from unittest.mock import patch

import defence_live as live
import lab_reset
import notebooks
import present


class DefenceTests(unittest.TestCase):
    def test_prometheus_labels_do_not_depend_on_order(self):
        text = ('# TYPE agentgateway_requests_total counter\n'
                'agentgateway_requests_total{reason="JwtAuth",status="401",caller="alice"} 2\n'
                'agentgateway_requests_total{status="429",reason="DirectResponse"} 3\n'
                'agentgateway_requests_total_other{status="401"} 100\n')
        samples = live.samples(text, "agentgateway_requests_total")
        self.assertEqual(len(samples), 2)
        self.assertEqual(sum(n for labels, n in samples if labels["reason"] == "JwtAuth"), 2)

    def test_ztunnel_scoping_and_double_counting(self):
        item = {"src.namespace": "dd-agents", "src.workload": "defence-agent-abc-123",
                "src.identity": "spiffe://mesh1/ns/dd-agents/sa/defence-agent",
                "dst.namespace": "dd-tools", "direction": "inbound", "conn_id": "123",
                "error": "connection closed due to policy rejection: allow policies exist, but none allowed",
                "time": "2026-09-27T14:30:00Z"}
        records = [item, item, {**item, "direction": "outbound"},
                   {**item, "src.namespace": "other-lab"},
                   {**item, "src.identity": "spiffe://mesh1/ns/dd-agents/sa/other-agent"},
                   {**item, "dst.namespace": "other-lab"},
                   {**item, "time": "2026-09-26T14:30:00Z"},
                   {**item, "error": "connection reset"}]
        text = "not JSON\n" + "\n".join("[pod/ztunnel] " + json.dumps(r) for r in records)
        self.assertEqual(live.workload_refusals(text, "2026-09-27T00:00:00Z"), [item])

    def test_reset_is_not_an_unreachable_cluster(self):
        with patch.object(live, "kubectl", return_value=""):
            result = live._collect()
        self.assertTrue(result["reset"])
        self.assertTrue(all(r["status"] == "Not deployed" for r in result["layers"]))
        with patch.object(live, "_cache", None), patch.object(live, "kubectl", side_effect=RuntimeError("API unavailable")):
            result = live.state()
        self.assertFalse(result["ok"])
        self.assertNotIn("layers", result)

    def test_reset_touches_only_owned_resources(self):
        source = lab_reset.reset_script("demo-13")
        self.assertIn("delete namespace dd-agents dd-models dd-tools dd-gateway", source)
        self.assertIn("delete service dd-rate-limiter", source)
        for forbidden in ("ai-models", "mcp-servers", "bookinfo", "petshop", "rollout restart", "helm", "delete cluster"):
            self.assertNotIn(forbidden, source)

    def test_pending_policy_is_not_shown_as_open_or_enforced(self):
        policy = {"kind": "EnterpriseAgentgatewayPolicy", "metadata": {"name": "caller-identity", "generation": 2},
                  "status": {"ancestors": [{"conditions": [
                      {"type": t, "status": "True", "observedGeneration": 1} for t in ("Accepted", "Attached")]}]}}
        pod = {"kind": "Pod", "metadata": {"name": "gateway-pod", "labels": {
            "gateway.networking.k8s.io/gateway-name": "dd-gateway"}},
            "status": {"conditions": [{"type": "Ready", "status": "True"}]}}

        def fake(*args):
            if args[:2] == ("get", "ns"):
                return json.dumps({"metadata": {"uid": "test", "creationTimestamp": "2026-09-27T00:00:00Z"}})
            if "pod,enterpriseagentgatewaypolicy,ratelimitconfig,gateway" in args:
                return json.dumps({"items": [pod, policy]})
            if "pod,authorizationpolicy,agent" in args:
                waypoint = {**pod, "metadata": {"name": "waypoint-pod", "labels": {
                    "gateway.networking.k8s.io/gateway-name": "dd-egress"}}}
                return json.dumps({"items": [waypoint]})
            if "-o" in args:
                return '{"items": []}'
            return ""

        with patch.object(live, "kubectl", side_effect=fake), patch.object(live, "_history", {"uid": None, "workload": {}, "tools": {}}):
            result = live._collect()
        caller = next(r for r in result["layers"] if r["id"] == "caller")
        self.assertEqual(caller["status"], "Pending / rejected")
        egress = next(r for r in result["layers"] if r["id"] == "egress")
        self.assertEqual((egress["status"], egress["count"]), ("Open", 0))

    def test_every_action_has_real_output_fixture(self):
        demo = notebooks.load("demo-13")
        for chapter in demo.story:
            for action in present.actions(demo, chapter):
                fixture = notebooks.ROOT / "present/fixtures/demo-13" / f"{chapter.id}_{action['index']}.txt"
                self.assertTrue(fixture.is_file(), str(fixture))
                self.assertTrue(fixture.read_text().strip())

    def test_runtime_is_owned_by_kagent(self):
        demo = notebooks.load("demo-13")
        code = "\n".join(block.source for chapter in demo.story for block in chapter.blocks if block.kind == "code")
        self.assertRegex(code, r"kind: Agent\n")
        self.assertRegex(code, r"kind: MCPServer\n")
        self.assertIn("kind: ModelConfig", code)
        self.assertNotRegex(code, r"kind: (Pod|Deployment)\n")
        self.assertNotIn("unmanaged-agent", code)
        self.assertNotIn("llm-gateway-mock", code)
        self.assertNotIn("create configmap", code)

    def test_tool_refusals_count_only_the_agent_identity(self):
        base = ('info request gateway=dd-gateway/dd-waypoint route=dd-gateway/tools src.identity={id} http.status=400 '
                'protocol=mcp mcp.method.name=tools/call error="mcp: Unknown tool: close_all_incidents" reason=MCP')
        text = "\n".join([base.format(id=live.AGENT_ID),
                          base.format(id="spiffe://mesh1/ns/other/sa/defence-agent"),
                          base.format(id=live.AGENT_ID).replace("tools/call", "tools/list")])
        self.assertEqual(len(live.tool_refusals(text)), 1)

    def test_agent_holds_no_user_token_or_provider_key(self):
        agent = (live.Path(notebooks.NOTEBOOKS) / "demo-scripts/defence/04-agent.yaml").read_text()
        for forbidden in ("headersFrom", "Authorization", "dd-agent-identity", "apiKeyPassthrough", "anthropic-secret"):
            self.assertNotIn(forbidden, agent)
        self.assertIn("baseUrl: http://model.dd-gateway.svc/v1", agent)
        self.assertIn("url: http://tools.dd-gateway.svc/mcp", agent)

    def test_policies_follow_the_hardened_patterns(self):
        d = live.Path(notebooks.NOTEBOOKS) / "demo-scripts/defence"
        mesh = (d / "03-mesh-gateway.yaml").read_text()
        self.assertIn("gatewayClassName: enterprise-agentgateway-waypoint", mesh)
        self.assertEqual(mesh.count("failureMode: FailClosed"), 1)
        self.assertNotIn("static: {host: defence-operations", mesh)  # static hosts are dialled without mesh identity
        self.assertIn("failureMode: FailClosed", (d / "02-front-door.yaml").read_text())
        tools = (d / "09-tool-permissions.yaml").read_text()
        self.assertIn('source.identity.serviceAccount == "defence-agent"', tools)
        self.assertNotIn("jwt.", tools)
        for name in ("07-workload-identity.yaml", "08-caller-identity.yaml"):
            self.assertIn("selector:", (d / name).read_text(), name)

    def test_notebook_waits_for_policies_and_sets_its_own_tokens(self):
        demo = notebooks.load("demo-13")
        code = "\n".join(block.source for chapter in demo.story for block in chapter.blocks if block.kind == "code")
        self.assertNotIn("sleep 2", code)
        for condition in ("WaypointAccepted", "ZtunnelAccepted"):
            self.assertIn("--for=condition=" + condition, code)
        nb = json.loads((live.Path(notebooks.NOTEBOOKS) / "demo-13-defence-in-depth.ipynb").read_text())
        connect = next("".join(c["source"]) for c in nb["cells"] if c["cell_type"] == "code")
        for var in ("ALICE", "ADMIN", "DD_TOOLS"):
            self.assertIn("export " + var if var != "DD_TOOLS" else var, connect)

    def test_every_chapter_has_the_architecture_tab(self):
        demo = notebooks.load("demo-13")
        for chapter in demo.story:
            page = present.view(demo, chapter)
            self.assertIn('data-tab="diagram"', page)
            self.assertIn('id="defence-architecture"', page)


if __name__ == "__main__":
    unittest.main()
