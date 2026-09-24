#!/usr/bin/env python3
"""Offline checks for profile selection and edition parity. Standard library only."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("render", Path(__file__).with_name("render.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
ROOT = module.ROOT


class RenderTests(unittest.TestCase):
    def test_content_addressed_selection_and_rollback(self):
        path = ROOT / "config/task-routing.json"
        original = module.render("oss", "localhost/jev:part5", path, "task")
        cm, _ = json.JSONDecoder().raw_decode(original)
        self.assertTrue(cm["immutable"])
        self.assertIn("name: " + cm["metadata"]["name"], original)
        with tempfile.TemporaryDirectory() as directory:
            changed = Path(directory) / "profile.json"
            profile = json.loads(path.read_text())
            profile["minConfidence"] = 0.9
            changed.write_text(json.dumps(profile))
            rendered = module.render("oss", "localhost/jev:part5", changed, "task")
            new_cm, _ = json.JSONDecoder().raw_decode(rendered)
            self.assertNotEqual(cm["metadata"]["name"], new_cm["metadata"]["name"])
            self.assertIn("name: " + new_cm["metadata"]["name"], rendered)
        self.assertEqual(original, module.render("oss", "localhost/jev:part5", path, "task"))

    def test_support_profile_is_selected_without_image_change(self):
        rendered = module.render("oss", "localhost/jev:part5", ROOT / "config/support-routing.json",
                                 "support", ROOT / "yaml-oss/31-support-routes.yaml")
        cm, _ = json.JSONDecoder().raw_decode(rendered)
        self.assertEqual(json.loads(cm["data"]["profile.json"])["questionId"], "department")
        self.assertIn("value: technical", rendered)
        self.assertNotIn("value: generic_coding", rendered)

    def test_editions_differ_only_in_api_and_class(self):
        for filename in ["20-gateway.yaml", "30-routes.yaml", "31-support-routes.yaml"]:
            enterprise = (ROOT / "yaml" / filename).read_text()
            oss = enterprise.replace("enterpriseagentgateway.solo.io", "agentgateway.dev").replace(
                "EnterpriseAgentgateway", "Agentgateway").replace("enterprise-agentgateway", "agentgateway")
            self.assertEqual(oss, (ROOT / "yaml-oss" / filename).read_text())


if __name__ == "__main__":
    unittest.main()
