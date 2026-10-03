#!/usr/bin/env python3
"""Agentdesktop helpers for the demo console. Fleet is on kind-mesh1."""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

MESH = os.environ.get("MESH_CONTEXT", "kind-mesh1")
AD_NS = "agentdesktop"
VISION = Path(__file__).resolve().parents[1]
ENROL = VISION / "demo-scripts" / "agentdesktop-enrol-mac.sh"
# agw-toggle.sh --install writes a launcher to ~/Downloads; without one, use the lab's own copy.
AGW = Path(os.environ.get("AGW_TOGGLE") or next(
    (p for p in (Path.home() / "Downloads" / "agw-toggle.sh",
                 VISION.parent / "agentgateway-inference-task-routing-eks" / "scripts" / "agw-toggle.sh")
     if p.exists()), Path.home() / "Downloads" / "agw-toggle.sh"))
ADMIN = "http://127.0.0.1:18099"
SOCK = Path.home() / ".local/state/agentdesktop/agentdesktop.sock"
SYS_SOCK = Path("/var/run/agentdesktop/agentdesktop.sock")
SYS_PLIST = Path("/Library/LaunchDaemons/dev.agentdesktop.daemon.plist")
SYS_BIN = Path("/usr/local/bin/agentdesktop")
SYS_LOG = Path("/var/log/agentdesktop-daemon.log")
SYS_CODE_SETTINGS = Path("/Library/Application Support/ClaudeCode/managed-settings.d/50-agentdesktop.json")
SYS_DESKTOP_PLIST = Path("/Library/Managed Preferences/com.anthropic.claudefordesktop.plist")
CLAUDE = Path(os.environ.get("CLAUDE_SETTINGS", Path.home() / ".claude" / "settings.json"))
PF_LOG = Path("/tmp/ad-console-pf.log")
ENROL_LOG = Path("/tmp/ad-enrol.log")

def _gateway_url():
    # The shared EKS model gateway. Set AGW_HOST in console.env.
    return "https://" + os.environ.get("AGW_HOST", "agw.example.com")


# WebSearch and WebFetch are Anthropic server-side tools: the client declares them and
# Anthropic runs the search inside the call. A gateway serving self-hosted models has
# nothing to map them onto, the tool never resolves, and the turn retries until someone
# gives up. Denying them is the only way the enrolled clients behave, so both programs
# below carry the denial in the form their own settings take.
#
# The env block switches Vertex off. A laptop set up for a Vertex front door keeps
# CLAUDE_CODE_USE_VERTEX in ~/.claude/settings.json, and a running Claude Code already
# has it in its environment. Managed settings replace apiKeyHelper but leave that switch
# alone, so Claude Code stays on the Vertex path and posts the Agentdesktop token to the
# Vertex front door, which answers 401 'token uses the unknown key "agentdesktop"'.
# Managed env beats both the user file and the inherited environment.
LAB_DAEMON = """\
llmGateway:
  authentication:
    allowedClientIds:
__CLIENT_IDS__
    audience: model-gateway
    type: controllerJwt
  url: __GW__
programs:
  claudeCode:
    companyAnnouncements:
    - Managed by Agentdesktop. Model traffic goes through the EKS model gateway.
    env:
      CLAUDE_CODE_USE_VERTEX: "0"
      ANTHROPIC_CUSTOM_HEADERS: ""
    permissions:
      deny:
      - WebSearch
      - WebFetch
    useLlmGateway: true
"""

# Agentdesktop generates only inferenceProvider, inferenceGatewayBaseUrl and the
# credential-helper keys for Desktop. The auth scheme, the model list and the tool
# denials are pass-through, so they have to be written out here or Desktop tries model
# discovery against a gateway that does not serve it. Each value is a string because
# Desktop reads a flat managed value as a string and parses it.
#
# disableDeploymentModeChooser is what makes the rest of this block take effect. Desktop
# only applies a managed inference profile when it treats itself as third-party, and that
# decision is: the profile has an inference block AND either this key is true or the
# saved deploymentMode in ~/Library/Application Support/Claude/claude_desktop_config.json
# is not "1p". Agentdesktop never writes that user file, so on a machine that has ever
# signed in to Claude.ai the profile lands correctly and is then ignored. The toggle
# script gets away without the key because it writes deploymentMode: 3p itself.
DESKTOP_PROGRAM = """\
  claudeDesktop:
    disableDeploymentModeChooser: true
    disabledBuiltinTools: '["WebSearch", "WebFetch"]'
    inferenceGatewayAuthScheme: bearer
    inferenceModels: '["claude-sonnet-5"]'
    modelDiscoveryEnabled: "false"
    useLlmGateway: true
"""

# Who signs in: bob on /desktop, martink on /kernwerk/desktop.
SIGNIN_USERS = ("bob", "martink")


def _signin_user(user):
    return user if user in SIGNIN_USERS else "bob"


def _yaml(text, client_ids=("claude-code",)):
    return (text.replace("__GW__", _gateway_url())
                .replace("__CLIENT_IDS__", "\n".join("    - " + c for c in client_ids)))


POLICIES = {
    "lab": {
        "label": "Lab default",
        "blurb": "Claude Code goes through the EKS model gateway.",
        "yaml": None,
    },
    "lock-home": {
        "label": "Lock the home folder",
        "blurb": "Same EKS gateway, plus a sandbox that denies ~/.ssh, ~/.aws, ~/.gnupg and ~/Downloads.",
        "yaml": None,
        "kind": "lock-home",
    },
    "announce": {
        "label": "Show a company notice",
        "blurb": "Adds a line Claude Code shows on start, so you can see the revision land without changing the sandbox.",
        "yaml": None,
        "kind": "announce",
    },
    "both-clients": {
        "label": "Claude Code and Claude Desktop",
        "blurb": ("Manages both clients. Needs the system-mode enrol "
                  "(agentdesktop-enrol-mac.sh up-system): a daemon running as you cannot write "
                  "Desktop's managed preferences, and in --user mode this policy is refused "
                  "whole, which leaves Claude Code unmanaged too."),
        "yaml": None,
        "kind": "both-clients",
    },
}


def _policy_yaml(name: str) -> str:
    if name == "both-clients":
        # claude-desktop has to be an allowed client id of its own: Desktop's credential
        # helper asks the controller for one under that name, and the controller refuses
        # any id not on the list.
        return _yaml(LAB_DAEMON, ("claude-code", "claude-desktop")) + DESKTOP_PROGRAM
    base = _yaml(LAB_DAEMON)
    if name == "lock-home":
        return base + (
            "sandbox:\n"
            "  filesystem:\n"
            "    denied:\n"
            "    - ~/.ssh\n"
            "    - ~/.aws\n"
            "    - ~/.gnupg\n"
            "    - ~/Downloads\n"
            "    writable:\n"
            "    - ~/src\n"
        )
    if name == "announce":
        return base.replace(
            "EKS model gateway.",
            "EKS model gateway. Policy revision published from the demo console.",
        )
    return base


def kc(*args, check=True):
    return subprocess.run(
        ["kubectl", "--context", MESH, *args],
        check=check, text=True, capture_output=True,
    )


def admin_get(path, timeout=3):
    req = urllib.request.Request(ADMIN + path)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def admin_delete(path, timeout=3):
    req = urllib.request.Request(ADMIN + path, method="DELETE")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        r.read()
        return r.status


def _bin_running(path: Path) -> bool:
    """True only if a process was launched from this exact binary.

    `pgrep -f` matches its own argv, and a leftover tray binary named
    `./bin/agentdesktop` is not the system daemon."""
    if not path.exists():
        return False
    needle = str(path)
    p = subprocess.run(["ps", "-ax", "-o", "command="], capture_output=True, text=True)
    for line in (p.stdout or "").splitlines():
        cmd = line.strip()
        if cmd == needle or cmd.startswith(needle + " "):
            return True
    return False


def _socket_live(path: Path) -> bool:
    """True when a daemon is actually serving this socket.

    Deliberately not by connecting to it. The daemon inspects the peer credentials of every
    local API connection, and a peer that has already hung up is fatal to the whole process,
    not to that one connection:

        Error: inspect local API peer credentials
        Caused by: Socket is not connected (os error 57)

    A connect-and-close liveness probe is exactly that shape. This page refreshes every five
    seconds, so the probe killed the daemon every five seconds, launchd's KeepAlive revived
    it, and each start opened another sign-in page in the browser and invalidated the state
    and nonce of the one before it. Signing in was impossible.

    A leftover socket file is not a running daemon either, so the process list is the
    evidence: the socket has to exist and something has to be serving it.
    """
    if not path.exists():
        return False
    p = subprocess.run(["ps", "-ax", "-o", "command="], capture_output=True, text=True)
    flagged = f"--socket {path}"
    for line in p.stdout.splitlines():
        if "agentdesktop" not in line or " daemon" not in line:
            continue
        if flagged in line:
            return True
        # The user-mode daemon takes its socket from its state directory, with no flag.
        if path == SOCK and "--socket" not in line and "--user" in line:
            return True
    return False


def _this_host_names() -> set[str]:
    names = {socket.gethostname().split(".")[0].lower()}
    for key in ("ComputerName", "LocalHostName", "HostName"):
        p = subprocess.run(["scutil", "--get", key], capture_output=True, text=True)
        if p.returncode == 0 and p.stdout.strip():
            names.add(p.stdout.strip().split(".")[0].lower())
    return {n for n in names if n}


def _local_daemon_up() -> bool:
    return _socket_live(SOCK) or _socket_live(SYS_SOCK) or _bin_running(SYS_BIN)


def _is_local_orphan(device: dict) -> bool:
    os_name = (device.get("os") or "").lower()
    host = (device.get("hostname") or "").split(".")[0].lower()
    if os_name in ("macos", "darwin"):
        return True
    return host in _this_host_names()


def _device_list(payload):
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        return payload.get("devices") or []
    return []


def _drop_devices(devices):
    deleted = []
    for device in devices:
        device_id = device.get("id")
        if not device_id:
            continue
        try:
            admin_delete(f"/api/v1/devices/{device_id}")
            deleted.append(device_id)
        except Exception:
            pass
    return deleted


def purge_local_orphans():
    """Drop leftover controller rows for this Mac.

    Each enrol mints a new device id and logout only clears the local identity,
    so failed or repeated enrols leave MacBook rows in the fleet console. The
    mesh1 fleet is Linux, so any macos/darwin record is this laptop. When the
    daemon is not running, every such row is an orphan. When it is running,
    keep the most recently seen one and delete the rest."""
    try:
        local = [d for d in _device_list(admin_get("/api/v1/devices")) if _is_local_orphan(d)]
    except Exception:
        return []
    if not local:
        return []
    if not _local_daemon_up():
        return _drop_devices(local)
    local.sort(key=lambda d: d.get("last_seen_at") or 0, reverse=True)
    return _drop_devices(local[1:])


def ensure_port_forward():
    try:
        admin_get("/api/v1/overview", timeout=1)
        return True
    except Exception:
        pass
    subprocess.Popen(
        ["kubectl", "--context", MESH, "-n", AD_NS, "port-forward",
         "deploy/agentdesktop", "18099:8080"],
        stdout=open(PF_LOG, "ab"), stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    for _ in range(12):
        try:
            admin_get("/api/v1/overview", timeout=1)
            return True
        except Exception:
            time.sleep(0.4)
    return False


def agw_status():
    if not AGW.exists():
        return {"present": False, "on": False, "text": "agw-toggle.sh not found"}
    p = subprocess.run([str(AGW), "status"], text=True, capture_output=True)
    text = (p.stdout or "") + (p.stderr or "")
    native = "configured: native" in text
    return {"present": True, "on": (not native) and ("http://" in text or "https://" in text),
            "native": native, "text": text.strip()[:800]}


def claude_settings():
    if not CLAUDE.exists():
        return {"exists": False}
    d = json.loads(CLAUDE.read_text())
    env = d.get("env") or {}
    return {
        "exists": True,
        "path": str(CLAUDE),
        "base_url": env.get("ANTHROPIC_BASE_URL") or "",
        "api_key_helper": d.get("apiKeyHelper") or "",
        "announcements": d.get("companyAnnouncements") or [],
        "sandbox": d.get("sandbox") or {},
    }


def _names_resolve() -> bool:
    """The controller and Keycloak sslip.io names answer with their own addresses."""
    env = VISION / "demo-scripts" / ".agentdesktop-env"
    if not env.is_file():
        return False
    vals = dict(re.findall(r"^export (\w+)=(.*)$", env.read_text(), re.M))
    pairs = ((vals.get("AD_CONTROLLER_HOST") or f"agentdesktop.{vals.get('AD_CONTROLLER_IP')}.sslip.io",
              vals.get("AD_CONTROLLER_IP")),
             (vals.get("AD_KEYCLOAK_HOST") or f"keycloak.{vals.get('AD_KEYCLOAK_IP')}.sslip.io",
              vals.get("AD_KEYCLOAK_IP")))
    try:
        return all(ip and socket.gethostbyname(host) == ip for host, ip in pairs)
    except OSError:
        return False


def enrol_bits():
    daemon = _local_daemon_up()
    return {
        "script": ENROL.is_file(),
        "hosts": _names_resolve(),
        "binary": (VISION / "demo-scripts" / ".agentdesktop-bin" / "agentdesktop").is_file(),
        "daemon": daemon,
        "system": SYS_PLIST.exists() or _bin_running(SYS_BIN) or SYS_CODE_SETTINGS.exists(),
        # An Agentdesktop-written profile carries an .owner marker beside it. Without one
        # the plist belongs to agw-toggle.sh, and the two cannot both own Desktop.
        "desktop_managed": (SYS_DESKTOP_PLIST.exists()
                            and SYS_DESKTOP_PLIST.with_name(
                                "." + SYS_DESKTOP_PLIST.name + ".owner").exists()),
        "hostname": socket.gethostname().split(".")[0],
    }


def status():
    ensure_port_forward()
    purged = purge_local_orphans()
    fleet = {"ok": False}
    try:
        ov = admin_get("/api/v1/overview")
        devices = _device_list(admin_get("/api/v1/devices"))
        fleet = {
            "ok": True,
            "overview": ov,
            "devices": devices,
            "purged": purged,
            "console": ADMIN + "/",
        }
    except Exception as e:
        fleet = {"ok": False, "error": str(e)[:200], "purged": purged}
    return {
        "fleet": fleet,
        "daemon": daemon_state(),
        "agw": agw_status(),
        "claude": claude_settings(),
        "gateway_host": os.environ.get("AGW_HOST", "agw.example.com"),
        "enrol": enrol_bits(),
        "policies": {k: {"label": v["label"], "blurb": v["blurb"]} for k, v in POLICIES.items()},
    }


def agw_off():
    if not AGW.exists():
        return {"ok": False, "error": "agw-toggle.sh not found"}
    p = subprocess.run([str(AGW), "off"], text=True, capture_output=True)
    return {"ok": p.returncode == 0, "text": (p.stdout or p.stderr or "")[-1200:]}


def agw_on():
    if not AGW.exists():
        return {"ok": False, "error": "agw-toggle.sh not found"}
    env = {**os.environ, "AGW_SUBJECT": os.environ.get("AGW_SUBJECT", "bob")}
    p = subprocess.run([str(AGW), "on"], text=True, capture_output=True, env=env)
    return {"ok": p.returncode == 0, "text": (p.stdout or p.stderr or "")[-1500:]}


def _script(action: str, timeout=300):
    """Run one enrol-script action. The privileged ones raise macOS's own authorisation
    dialog, which a web request can wait on, so nothing has to go via a terminal. The
    timeout is generous because that dialog waits for a person."""
    try:
        p = subprocess.run(["bash", str(ENROL), action], cwd=str(VISION),
                           text=True, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 1, f"{action} is still waiting after {timeout}s. Answer the macOS prompt, then try again."
    return p.returncode, ((p.stdout or "") + (p.stderr or "")).strip()


def daemon_state():
    """Read from files rather than the daemon socket. Installing adds this user to the
    agentdesktop group, and a running process does not pick up a new group, so the
    console would otherwise need restarting before it could show anything."""
    owner = SYS_DESKTOP_PLIST.with_name("." + SYS_DESKTOP_PLIST.name + ".owner")
    running = _local_daemon_up()
    return {
        "installed": SYS_PLIST.exists() or running,
        "running": running,
        "code": SYS_CODE_SETTINGS.exists(),
        "desktop": SYS_DESKTOP_PLIST.exists() and owner.exists(),
        # A managed profile with no marker beside it belongs to agw-toggle.sh.
        "desktop_other": SYS_DESKTOP_PLIST.exists() and not owner.exists(),
    }


def daemon_install():
    if agw_status().get("on"):
        return {"ok": False, "error": "agw-toggle owns Claude right now. Release it first."}
    code, text = _script("install-daemon")
    if code:
        # -128 is the AppleScript code for someone dismissing the authorisation dialog.
        if "-128" in text or "User canceled" in text:
            return {"ok": False, "error": "Authorisation cancelled. Nothing was changed."}
        return {"ok": False, "error": text[-600:] or "install failed"}
    return {"ok": True, "text": "Daemon installed and running as the machine. Sign in next."}


def daemon_remove():
    code, text = _script("remove-daemon")
    purged = purge_local_orphans()
    if code:
        return {"ok": False, "error": text[-600:] or "remove failed", "purged": purged}
    return {"ok": True, "text": "Both clients are back to native. Restart Claude Code and reopen Desktop.",
            "purged": purged}


def signin(user="bob"):
    """The daemon publishes its authorization URL as soon as it wants a sign-in."""
    user = _signin_user(user)
    code, text = _script("signin-url", timeout=20)
    url = text.strip().splitlines()[-1] if text.strip() else ""
    if code or not url.startswith("http"):
        return {"ok": False, "error": text[-300:] or "no sign-in pending"}
    subprocess.run(["open", url], capture_output=True)
    return {"ok": True, "url": url,
            "text": f"Browser opened. Sign in as {user} / password."}


def _in_terminal(action: str, note: str):
    """System mode needs sudo, and a password prompt has nowhere to go in a web request,
    so hand the command to Terminal where the prompt can be answered."""
    command = f'cd {VISION} && ./demo-scripts/agentdesktop-enrol-mac.sh {action}'
    script = ('tell application "Terminal"\n'
              f'  do script "{command}"\n'
              '  activate\n'
              'end tell')
    p = subprocess.run(["osascript", "-e", script], text=True, capture_output=True)
    if p.returncode:
        return {"ok": False, "error": (p.stderr or "could not open Terminal")[-300:],
                "command": command}
    return {"ok": True, "text": note, "command": command}


def enrol_up_system(user="bob"):
    """Both clients. Claude Desktop is only reachable from a daemon running as the
    machine: Desktop reads its policy from /Library/Managed Preferences, which the
    user-mode daemon cannot write, and it refuses a policy carrying claudeDesktop
    whole, so Claude Code would go unmanaged too."""
    user = _signin_user(user)
    if agw_status().get("on"):
        return {"ok": False, "error": "Claude is still on the EKS gateway via agw-toggle. Release it first."}
    return _in_terminal("up-system",
                        "Terminal is asking for your password, then a sign-in URL. "
                        f"Open it and sign in as {user} / password. "
                        "Claude Code and Claude Desktop both land on the EKS gateway.")


def enrol_down_system():
    return _in_terminal("down-system", "Terminal is putting both clients back to native.")


def enrol_up():
    agw = agw_status()
    if agw.get("on"):
        return {"ok": False, "error": "Claude is still on the EKS gateway. Release it first."}
    if not ENROL.is_file():
        return {"ok": False, "error": "enrol script missing"}
    # already running
    if SOCK.exists():
        return {"ok": True, "already": True, "text": "daemon already running"}
    lab_bin = VISION / "demo-scripts" / ".agentdesktop-bin" / "agentdesktop"
    env = {**os.environ, "CTX": MESH}
    if lab_bin.is_file():
        env["AD_BIN"] = str(lab_bin)
    ENROL_LOG.write_text("")
    log = open(ENROL_LOG, "wb")
    subprocess.Popen(
        ["bash", str(ENROL), "up"],
        cwd=str(VISION),
        stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True,
        env=env,
    )
    time.sleep(1.5)
    tail = ENROL_LOG.read_text(errors="replace")[-1200:]
    if "unbound variable" in tail or "No agentdesktop binary" in tail:
        return {"ok": False, "error": tail.strip() or "enrol script failed"}
    if "Claude Desktop does not read inference settings" in tail:
        return {"ok": False, "error": (
            "The published policy carries Claude Desktop, and a user-mode device refuses it "
            "whole, so Claude Code is unmanaged too. Use the system-mode enrol, or publish "
            "the Claude Code-only policy first.")}
    if SOCK.exists():
        return {"ok": True, "already": False, "text": "daemon is up. Sign in as tom / password in the browser that opened."}
    return {
        "ok": True,
        "already": False,
        "text": (tail.strip() + "\nIf no browser opened, check the enrol log and try Enrol again.")[-1200:],
    }


def enrol_down():
    p = subprocess.run(["bash", str(ENROL), "down"], cwd=str(VISION), text=True, capture_output=True)
    purged = purge_local_orphans()
    return {"ok": p.returncode == 0, "text": (p.stdout or p.stderr or "")[-1500:],
            "purged": purged}


def apply_policy(name: str):
    if name not in POLICIES:
        return {"ok": False, "error": f"unknown policy {name}"}
    patch = json.dumps({"data": {"daemon.yaml": _policy_yaml(name)}})
    proc = kc("-n", AD_NS, "patch", "cm", "agentdesktop", "--type", "merge", "-p", patch, check=False)
    if proc.returncode != 0:
        return {"ok": False, "error": (proc.stderr or proc.stdout)[-400:]}
    return {"ok": True, "policy": name, "label": POLICIES[name]["label"]}
