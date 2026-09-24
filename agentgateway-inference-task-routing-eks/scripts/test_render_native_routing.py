import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("renderer", ROOT / "scripts/render-native-routing.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class NativeRenderingTests(unittest.TestCase):
    def test_install_time_jwks_substitution_remains_a_string_in_both_editions(self):
        jwks = json.dumps({"keys": [{"kid": "lab-key", "kty": "RSA", "n": "example", "e": "AQAB"}]})
        for directory in ["yaml", "yaml-oss"]:
            template = (ROOT / directory / "50-decide-policy.yaml.tmpl").read_text()
            rendered = yaml.safe_load(template.replace("__JWKS__", jwks).replace("__AD_JWKS__", jwks))
            providers = rendered["spec"]["traffic"]["jwtAuthentication"]["providers"]
            self.assertEqual([p["jwks"]["inline"] for p in providers], [jwks, jwks])

    def test_entitlement_update_changes_only_the_native_expression(self):
        from subprocess import CompletedProcess
        current = {"metadata": {"resourceVersion": "123"}, "spec": {"traffic": {"jwtAuthentication": {"providers": ["live-provider"]}}}}
        with patch.object(renderer.subprocess, "run", side_effect=[CompletedProcess([], 0, json.dumps(current)), CompletedProcess([], 0)]) as run:
            renderer.apply_data({"users": {}}, "test-context")
        args = run.call_args_list[1].args[0]
        operations = json.loads(args[args.index("-p") + 1])
        self.assertEqual(operations[0], {"op": "test", "path": "/metadata/resourceVersion", "value": "123"})
        self.assertEqual(operations[1]["path"], "/spec/traffic/transformation/request/metadata/routing")
        self.assertEqual(len(operations), 2)


if __name__ == "__main__":
    unittest.main()
