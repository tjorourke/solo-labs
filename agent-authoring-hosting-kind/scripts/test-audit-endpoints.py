#!/usr/bin/env python3
"""Regression checks for misleading audit verdicts; no cluster required."""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("audit", Path(__file__).with_name("audit-endpoints.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class AuditTests(unittest.TestCase):
    def test_denied_request(self):
        for code in (401, 403):
            self.assertEqual(audit.classify(code, "")[0], "DENIED")

    def test_only_valid_initialize_is_accepted(self):
        body = json.dumps({"jsonrpc": "2.0", "result": {
            "protocolVersion": "2025-03-26", "serverInfo": {"name": "test"}}})
        self.assertEqual(audit.classify(200, body)[0], "ACCEPTED")
        self.assertEqual(audit.classify(200, "data: " + body + "\n\n")[0], "ACCEPTED")
        for body in ("<html>login</html>", '{"error":{"code":-32601}}', "null", "{}",
                     '{"result":{"protocolVersion":1,"serverInfo":"invalid"}}'):
            self.assertEqual(audit.classify(200, body)[0], "INCONCLUSIVE")

    def test_failures_and_redirects_are_not_denials(self):
        for code in (0, 301, 404, 500):
            self.assertEqual(audit.classify(code, "")[0], "INCONCLUSIVE")
        self.assertEqual(audit.classify(200, "", 28)[0], "INCONCLUSIVE")

    def targets(self, kind="EnterpriseAgentgatewayBackend", hosts=None):
        route = {"metadata": {"name": "tools", "namespace": "demo"}, "spec": {
            "hostnames": hosts if hosts is not None else ["tools.example.com"],
            "parentRefs": [{"name": "edge"}], "rules": [{"backendRefs": [{"kind": kind}]}]}}
        gateway = {"metadata": {"name": "edge", "namespace": "demo"}, "spec": {"listeners": [
            {"name": "http", "protocol": "HTTP", "port": 8080},
            {"name": "https", "protocol": "HTTPS", "port": 443}]}}
        return list(audit.route_targets([route], [gateway], "/custom-mcp"))

    def test_service_backend_does_not_imply_login(self):
        result = self.targets("Service")[0]
        self.assertEqual(result["status"], "NOT_TESTED")
        self.assertNotIn("has its own login", result["detail"])

    def test_wildcard_and_missing_hosts_remain_untested(self):
        for hosts in ([], ["*.example.com"], ["tools.demo.svc.cluster.local"]):
            self.assertEqual(self.targets(hosts=hosts)[0]["status"], "NOT_TESTED")

    def test_listener_scheme_port_and_probe_path(self):
        self.assertEqual([r["url"] for r in self.targets()], [
            "http://tools.example.com:8080/custom-mcp", "https://tools.example.com/custom-mcp"])


if __name__ == "__main__":
    unittest.main()
