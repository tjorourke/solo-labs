#!/usr/bin/env python3
"""Switch the lab's two Claude clients without leaving Desktop's managed profile active."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

PROFILE_KEYS = {
    "inferenceProvider", "inferenceGatewayBaseUrl", "inferenceCredentialKind",
    "inferenceGatewayAuthScheme", "inferenceGatewayApiKey", "inferenceModels",
    "modelDiscoveryEnabled",
}


def read_json(path):
    return json.loads(path.read_text()) if path.exists() else {}


def read_plist(path):
    return plistlib.loads(path.read_bytes()) if path.exists() else {}


def atomic_write(path, content, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(content)
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def json_bytes(value):
    return (json.dumps(value, indent=2) + "\n").encode()


class Toggle:
    def __init__(self):
        home = Path.home()
        self.lab = Path(os.environ.get("LAB_DIR", Path(__file__).resolve().parents[1]))
        self.base = "https://" + os.environ.get("AGW_HOST", "agw.awslab.masterthemesh.com")
        self.token = Path(os.environ.get("AGW_TOKEN_FILE", home / ".config/agw/token")).expanduser()
        self.subject = os.environ.get("AGW_SUBJECT", "bob")
        self.model = os.environ.get("AGW_DESKTOP_MODEL", "claude-sonnet-5")
        self.code = Path(os.environ.get("CLAUDE_SETTINGS", home / ".claude/settings.json"))
        support = home / "Library/Application Support"
        self.desktop = [
            Path(os.environ.get("CLAUDE_DESKTOP_CONFIG", support / "Claude/claude_desktop_config.json")),
            Path(os.environ.get("CLAUDE_DESKTOP_3P_CONFIG", support / "Claude-3p/claude_desktop_config.json")),
        ]
        self.managed = Path(os.environ.get("CLAUDE_MANAGED_PLIST",
                            "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"))
        self.user_managed = self.managed.parent / home.name / self.managed.name
        self.state = Path(os.environ.get("AGW_STATE_DIR", home / ".config/agw/toggle"))

    def helper(self):
        return "cat " + shlex.quote(str(self.token))

    def check_ownership(self):
        """Do not replace another demo's endpoint or an organisation's inference profile."""
        for path in (self.managed, self.user_managed):
            profile = read_plist(path)
            if path == self.user_managed and any(k.startswith('inference') for k in profile):
                raise RuntimeError(f"A per-user managed inference profile is active at {path}; update its owner first.")
            if any(k.startswith('inference') for k in profile):
                if (profile.get('inferenceProvider') != 'gateway'
                        or profile.get('inferenceGatewayBaseUrl', '').rstrip('/') != self.base):
                    raise RuntimeError(f"A different inference configuration owns {path}; left unchanged.")
                extras = {k for k in profile if k.startswith('inference')} - PROFILE_KEYS
                if extras:
                    raise RuntimeError(f"Additional inference policy in {path}; refusing to replace it: {sorted(extras)}")
        code = read_json(self.code)
        url = code.get('env', {}).get('ANTHROPIC_BASE_URL')
        if url and url.rstrip('/') != self.base:
            raise RuntimeError("Claude Code belongs to another gateway/demo. Stop that demo first.")
        helper = code.get('apiKeyHelper')
        if helper and helper not in (self.helper(), f"cat {self.token}"):
            raise RuntimeError("Claude Code has another credential helper. Stop its owner first.")
        for path in self.desktop:
            read_json(path)  # Fail on malformed config before making any changes.

    def ensure_token(self):
        if self.subject not in ('bob', 'alice', 'dave'):
            raise RuntimeError("AGW_SUBJECT must be bob, alice or dave")
        try:
            raw = self.token.read_text().strip().split('.')[1]
            claims = json.loads(base64.urlsafe_b64decode(raw + '=' * (-len(raw) % 4)))
            if (isinstance(claims, dict) and claims.get('sub') == self.subject
                    and int(claims.get('exp', 0)) > time.time() + 60):
                return
        except (OSError, ValueError, IndexError, TypeError):
            pass
        if not (self.lab / 'identity/signing-key.pem').is_file():
            raise RuntimeError("No existing lab signing key. Complete the identity/JWKS setup before minting.")
        mint = subprocess.run(['bash', str(self.lab / 'scripts/01-identity.sh')],
                              cwd=self.lab, capture_output=True, text=True)
        if mint.returncode:
            raise RuntimeError("Token minting failed; run scripts/01-identity.sh in the lab to diagnose.")
        result = subprocess.run(['bash', '-c', 'source "$1"; printf "%s" "${!2}"',
                                 'mint', str(self.lab / 'identity/tokens.env'),
                                 self.subject.upper() + '_TOKEN'], capture_output=True, check=True)
        if not result.stdout:
            raise RuntimeError("Minting produced an empty token")
        atomic_write(self.token, result.stdout)
        print(f"Minted a fresh token for {self.subject} using the existing lab key.")

    def preflight(self):
        self.ensure_token()
        body = json_bytes({'model': self.model, 'max_tokens': 8,
                           'messages': [{'role': 'user', 'content': 'Reply only with OK.'}]})
        req = urllib.request.Request(self.base + '/v1/messages', data=body, headers={
            'Authorization': 'Bearer ' + self.token.read_text().strip(),
            'Content-Type': 'application/json', 'anthropic-version': '2023-06-01'})
        try:
            with urllib.request.urlopen(req, timeout=90) as response:
                if response.status != 200:
                    raise RuntimeError(f"Gateway returned HTTP {response.status}")
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"Gateway returned HTTP {error.code}; client settings were not changed.") from error
        print("Gateway answered HTTP 200.")

    def snapshot(self, paths):
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.state.chmod(0o700)
        backup = Path(tempfile.mkdtemp(prefix='backup-', dir=self.state))
        for i, path in enumerate(paths):
            if path.exists():
                atomic_write(backup / f'{i}-{path.name}', path.read_bytes())
        return backup

    def managed_change(self, data):
        """Only the final install/remove runs with administrator privileges."""
        if data == read_plist(self.managed):
            return
        if not str(self.managed).startswith('/Library/Managed Preferences/'):
            # Alternate paths permit isolated tests without touching macOS preferences.
            if data:
                atomic_write(self.managed, plistlib.dumps(data))
            else:
                self.managed.unlink(missing_ok=True)
            return
        with tempfile.TemporaryDirectory(prefix='profile-', dir=self.state) as directory:
            payload = Path(directory, 'profile.plist')
            if data:
                atomic_write(payload, plistlib.dumps(data))
                commands = [['/bin/mkdir', '-p', str(self.managed.parent)],
                            ['/usr/bin/install', '-m', '644', '-o', 'root', '-g', 'wheel',
                             str(payload), str(self.managed)]]
            else:
                commands = [['/bin/rm', '-f', str(self.managed)]]
            command = ' && '.join(shlex.join(c) for c in commands)
            if subprocess.run(['sudo', '-n', 'true'], capture_output=True).returncode == 0:
                subprocess.run(['sudo', '-n', '/bin/sh', '-c', command], check=True)
            elif sys.stdin.isatty():
                subprocess.run(['sudo', '/bin/sh', '-c', command], check=True)
            else:
                print("macOS will ask permission to update the lab's Desktop managed profile.", flush=True)
                subprocess.run(['osascript', '-e', 'on run argv', '-e',
                                'do shell script (item 1 of argv) with administrator privileges',
                                '-e', 'end run', command], check=True)
        if read_plist(self.managed) != data:
            raise RuntimeError("Managed profile did not reach the requested state")

    def stop_desktop(self):
        if subprocess.run(['pgrep', '-x', 'Claude'], capture_output=True).returncode:
            return False
        subprocess.run(['osascript', '-e', 'tell application "Claude" to quit'], check=True)
        for _ in range(60):
            if subprocess.run(['pgrep', '-x', 'Claude'], capture_output=True).returncode:
                return True
            time.sleep(1)
        raise RuntimeError("Desktop has not quit. Resolve any save prompt, then run the toggle again.")

    def apply(self, mode, restart=True):
        self.check_ownership()
        if mode == 'on':
            self.preflight()
        code = read_json(self.code)
        profile = read_plist(self.managed)
        original_profile = dict(profile)
        # Retain all unrelated managed settings when disabling the demo.
        if profile.get('inferenceGatewayBaseUrl', '').rstrip('/') == self.base:
            for key in PROFILE_KEYS:
                profile.pop(key, None)
        if mode == 'on':
            profile.update({
                'inferenceProvider': 'gateway', 'inferenceGatewayBaseUrl': self.base,
                'inferenceCredentialKind': 'apiKey', 'inferenceGatewayAuthScheme': 'bearer',
                'inferenceGatewayApiKey': self.token.read_text().strip(),
                'inferenceModels': json.dumps([self.model]), 'modelDiscoveryEnabled': 'false',
            })
        env = code.setdefault('env', {})
        if mode == 'on':
            env['ANTHROPIC_BASE_URL'] = self.base
            code['apiKeyHelper'] = self.helper()
        else:
            env.pop('ANTHROPIC_BASE_URL', None)
            code.pop('apiKeyHelper', None)
        env.pop('CLAUDE_CODE_SIMPLE', None)
        if not env:
            code.pop('env', None)
        updates = {self.code: code}
        for path in self.desktop:
            if path.exists():
                config = read_json(path)
                config['deploymentMode'] = '3p' if mode == 'on' else '1p'
                # Remove only legacy flat settings for this lab, not unrelated preferences.
                if mode == 'off' and config.get('inferenceGatewayBaseUrl', '').rstrip('/') == self.base:
                    for key in PROFILE_KEYS:
                        config.pop(key, None)
                updates[path] = config
        backup = self.snapshot([self.managed, *updates])
        previous = {p: p.read_bytes() if p.exists() else None for p in updates}
        was_running = self.stop_desktop() if restart else False
        try:
            self.managed_change(profile)  # Auth cancellation leaves both clients unchanged.
            try:
                for path, value in updates.items():
                    atomic_write(path, json_bytes(value))
            except Exception:
                for path, old in previous.items():
                    if old is None:
                        path.unlink(missing_ok=True)
                    else:
                        atomic_write(path, old)
                self.managed_change(original_profile)
                raise
        except Exception:
            if was_running:
                subprocess.run(['open', '-a', 'Claude'], check=True)
            raise
        if restart:
            subprocess.run(['open', '-a', 'Claude'], check=True)
            print("Claude Desktop relaunched with the new configuration.")
        else:
            print("Configuration updated; fully quit and reopen Desktop to load it.")
        self.status()
        print(f"Backup: {backup}")
        print("Restart existing terminal Claude Code sessions; they keep their startup settings.")

    def status(self):
        code_url = read_json(self.code).get('env', {}).get('ANTHROPIC_BASE_URL')
        print('Claude Code configured:', code_url or 'native (no gateway base URL)')
        profiles = [read_plist(p) for p in (self.managed, self.user_managed)]
        active = [p for p in profiles if p.get('inferenceProvider') or p.get('inferenceGatewayBaseUrl')]
        if active:
            print('Claude Desktop configured:', ', '.join(p.get('inferenceGatewayBaseUrl', p.get('inferenceProvider', 'managed')) for p in active))
        elif any(read_json(p).get('deploymentMode') == '3p' for p in self.desktop):
            print('Claude Desktop: saved third-party mode remains; run off to restore native mode.')
        else:
            print('Claude Desktop configured: native (no managed inference override, no saved 3p mode)')
        print('Status describes configuration on disk; existing processes may still hold old settings.')

    def install(self):
        path = Path(os.environ.get('AGW_INSTALL_DEST', Path.home() / 'Downloads/agw-toggle.sh'))
        helper = self.lab / 'scripts/agw-toggle.py'
        if not helper.is_file():
            raise RuntimeError(f"Missing implementation: {helper}")
        if path.exists():
            self.snapshot([path])
        launcher = '#!/usr/bin/env bash\nset -euo pipefail\n'
        launcher += 'export LAB_DIR=' + shlex.quote(str(self.lab)) + '\n'
        launcher += 'exec python3 "$LAB_DIR/scripts/agw-toggle.py" "$@"\n'
        atomic_write(path, launcher.encode(), 0o755)
        print(f"Installed {path}; it uses the lab implementation at {helper}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', nargs='?', choices=['on', 'off', 'toggle', 'status', 'install'], default='status')
    parser.add_argument('--install', action='store_true', dest='install')
    parser.add_argument('--setup-desktop', '--seed-desktop', action='store_true', dest='seed')
    parser.add_argument('--unseed-desktop', action='store_true', dest='unseed')
    parser.add_argument('--no-restart', action='store_true', help='write configuration but leave the app lifecycle to you')
    args = parser.parse_args()
    toggle = Toggle()
    action = 'install' if args.install else 'on' if args.seed else 'off' if args.unseed else args.action
    if action == 'toggle':
        active = bool(read_json(toggle.code).get('env', {}).get('ANTHROPIC_BASE_URL'))
        active = active or any(read_plist(p).get('inferenceProvider') for p in (toggle.managed, toggle.user_managed))
        active = active or any(read_json(p).get('deploymentMode') == '3p' for p in toggle.desktop)
        action = 'off' if active else 'on'
    if action in ('on', 'off'):
        toggle.apply(action, restart=not args.no_restart)
    elif action == 'install':
        toggle.install()
    else:
        toggle.status()


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Toggle failed: {error}", file=sys.stderr)
        sys.exit(1)
