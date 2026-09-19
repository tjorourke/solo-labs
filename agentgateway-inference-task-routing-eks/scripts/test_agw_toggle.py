#!/usr/bin/env python3
"""Regression tests use temporary files, never the machine's Claude configuration."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('agw_toggle', Path(__file__).with_name('agw-toggle.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ToggleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='agw-toggle-test-')
        self.root = Path(self.directory.name)
        self.env = patch.dict(os.environ, {
            'CLAUDE_SETTINGS': str(self.root / 'code/settings.json'),
            'CLAUDE_DESKTOP_CONFIG': str(self.root / 'Claude/claude_desktop_config.json'),
            'CLAUDE_DESKTOP_3P_CONFIG': str(self.root / 'Claude-3p/claude_desktop_config.json'),
            'CLAUDE_MANAGED_PLIST': str(self.root / 'managed/claude.plist'),
            'AGW_STATE_DIR': str(self.root / 'state'),
            'AGW_TOKEN_FILE': str(self.root / 'token'),
            'AGW_HOST': 'agw.example.com',
        })
        self.env.start()
        self.toggle = module.Toggle()
        module.atomic_write(self.toggle.token, b'fixture-token')
        self.preflight = patch.object(self.toggle, 'preflight')
        self.preflight.start()
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()

    def tearDown(self):
        self.output.__exit__(None, None, None)
        self.preflight.stop()
        self.env.stop()
        self.directory.cleanup()

    def seed(self):
        module.atomic_write(self.toggle.code, module.json_bytes({'theme': 'dark', 'env': {'KEEP': 'yes'}}))
        for path in self.toggle.desktop:
            module.atomic_write(path, module.json_bytes({'preferences': {'keep': True}, 'deploymentMode': '1p'}))

    def test_on_off_updates_both_profiles_and_preserves_preferences(self):
        self.seed()
        self.toggle.apply('on', restart=False)
        profile = module.read_plist(self.toggle.managed)
        self.assertEqual(profile['inferenceGatewayBaseUrl'], self.toggle.base)
        self.assertEqual(profile['inferenceGatewayAuthScheme'], 'bearer')
        self.assertTrue(all(isinstance(value, str) for value in profile.values()))
        self.assertEqual(json.loads(profile['inferenceModels']), ['claude-sonnet-5'])
        self.toggle.apply('off', restart=False)
        self.assertFalse(self.toggle.managed.exists())
        self.assertEqual(module.read_json(self.toggle.code), {'theme': 'dark', 'env': {'KEEP': 'yes'}})
        for path in self.toggle.desktop:
            self.assertEqual(module.read_json(path), {'preferences': {'keep': True}, 'deploymentMode': '1p'})
        self.toggle.apply('off', restart=False)  # Repeated off must remain off.
        self.assertFalse(self.toggle.managed.exists())

    def test_reproduces_original_bug_with_plist_but_no_local_gateway_key(self):
        self.seed()
        self.toggle.apply('on', restart=False)
        # This is the app's real shape: local deploymentMode but no gateway URL.
        for path in self.toggle.desktop:
            self.assertNotIn('inferenceGatewayBaseUrl', module.read_json(path))
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.toggle.status()
        self.assertIn('Claude Desktop configured: https://agw.example.com', output.getvalue())
        self.toggle.apply('off', restart=False)
        self.assertFalse(self.toggle.managed.exists())

    def test_off_keeps_unrelated_managed_settings(self):
        self.seed()
        self.toggle.apply('on', restart=False)
        profile = module.read_plist(self.toggle.managed)
        profile['unrelatedPreference'] = 'keep'
        module.atomic_write(self.toggle.managed, plistlib.dumps(profile))
        self.toggle.apply('off', restart=False)
        self.assertEqual(module.read_plist(self.toggle.managed), {'unrelatedPreference': 'keep'})

    def test_authorisation_failure_leaves_both_clients_unchanged(self):
        self.seed()
        self.toggle.apply('on', restart=False)
        paths = [self.toggle.managed, self.toggle.code, *self.toggle.desktop]
        before = {p: p.read_bytes() for p in paths}
        with patch.object(self.toggle, 'managed_change', side_effect=PermissionError('cancelled')):
            with self.assertRaises(PermissionError):
                self.toggle.apply('off', restart=False)
        self.assertEqual(before, {p: p.read_bytes() for p in paths})

    def test_foreign_configuration_is_not_removed(self):
        self.seed()
        module.atomic_write(self.toggle.managed, plistlib.dumps({
            'inferenceProvider': 'gateway', 'inferenceGatewayBaseUrl': 'https://other.example.com'}))
        before = self.toggle.managed.read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'different inference configuration'):
            self.toggle.apply('off', restart=False)
        self.assertEqual(before, self.toggle.managed.read_bytes())

    def test_malformed_config_does_not_partially_switch(self):
        self.seed()
        module.atomic_write(self.toggle.desktop[1], b'not json')
        with self.assertRaises(ValueError):
            self.toggle.apply('on', restart=False)
        self.assertFalse(self.toggle.managed.exists())
        self.assertNotIn('ANTHROPIC_BASE_URL', module.read_json(self.toggle.code)['env'])

    def test_off_never_calls_gateway_or_mints_a_token(self):
        self.seed()
        self.toggle.token.unlink()
        self.toggle.apply('off', restart=False)
        self.toggle.preflight.assert_not_called()
        self.assertFalse(self.toggle.token.exists())

    def test_restart_happens_after_mode_is_changed(self):
        self.seed()
        def launch(command, **kwargs):
            self.assertEqual(command, ['open', '-a', 'Claude'])
            self.assertFalse(self.toggle.managed.exists())
            self.assertEqual(module.read_json(self.toggle.desktop[1])['deploymentMode'], '1p')
            return subprocess.CompletedProcess(command, 0)
        with patch.object(self.toggle, 'stop_desktop', return_value=True) as stop:
            with patch.object(module.subprocess, 'run', side_effect=launch):
                self.toggle.apply('off')
        stop.assert_called_once()

    def test_download_launcher_uses_lab_from_any_directory(self):
        install = self.root / 'Downloads/agw-toggle.sh'
        with patch.dict(os.environ, {'AGW_INSTALL_DEST': str(install),
                                   'LAB_DIR': str(Path(__file__).resolve().parents[1])}):
            toggle = module.Toggle()
            toggle.install()
            result = subprocess.run([str(install), 'status'], cwd=self.root,
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Claude Desktop configured: native', result.stdout)
        self.assertNotIn('fixture-token', result.stdout)


if __name__ == '__main__':
    unittest.main()
