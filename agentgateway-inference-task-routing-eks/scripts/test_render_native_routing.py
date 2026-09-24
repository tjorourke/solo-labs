import importlib.util
import json
from pathlib import Path
import unittest

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

    def test_generated_policies_round_trip_without_embedding_the_identity_directory(self):
        for edition, directory in [("enterprise", "yaml"), ("oss", "yaml-oss")]:
            expected = renderer.policies(edition)
            for policy, filename in zip(expected, ["50-decide-policy.yaml.tmpl", "51-routing-outcome.yaml"]):
                self.assertEqual(yaml.safe_load((ROOT / directory / filename).read_text()), policy)
                text = json.dumps(policy)
                self.assertNotIn('"users"', text)
                self.assertNotIn('.with(', text)


if __name__ == "__main__":
    unittest.main()
