"""A shell per lab, docked at the bottom of the lab pages.

Each lab gets one bash in a pseudo-terminal, started in the suite folder with
the lab's own environment (the same preamble its steps run with) and its own
kubeconfig holding only that lab's clusters. Plain `kubectl` therefore talks to
the right cluster, and the user's global kubeconfig context is never changed.

The shell outlives page loads: output is kept in a buffer, and a page that
reconnects asks for everything from an offset, so moving between chapters keeps
the scrollback. Only the console's own pages can drive it: every call needs the
per-process token the pages carry, and requests from another origin or host are
refused. The server only listens on 127.0.0.1.
"""
from __future__ import annotations

import fcntl
import os
import pty
import secrets
import select
import signal
import struct
import subprocess
import tempfile
import termios
import threading
from pathlib import Path

import notebooks

TOKEN = secrets.token_urlsafe(24)
BUFFER_MAX = 512 * 1024
_dir = Path(tempfile.mkdtemp(prefix="demo-console-term-"))
_sessions: dict[str, "Session"] = {}
_lock = threading.Lock()


def contexts(lab: str) -> list[str]:
    if lab == "demo-1":
        return [os.environ.get("CLUSTER1", "kind-mesh1"), os.environ.get("CLUSTER2", "kind-mesh2")]
    return list(notebooks.DEMOS[lab].get("clusters") or [os.environ.get("CTX", "kind-mesh1")])


def kubeconfig(lab: str) -> Path:
    """A kubeconfig with only this lab's contexts, current set to the first."""
    parts = []
    for ctx in contexts(lab):
        part = _dir / f"{lab}-{ctx}.yaml"
        raw = subprocess.run(["kubectl", "config", "view", "--raw", "--flatten", "--minify", "--context", ctx],
                             capture_output=True, text=True, timeout=15).stdout
        part.write_text(raw)
        parts.append(str(part))
    merged = subprocess.run(["kubectl", "config", "view", "--raw", "--flatten"], capture_output=True, text=True,
                            timeout=15, env={**os.environ, "KUBECONFIG": ":".join(parts)}).stdout
    path = _dir / f"{lab}.kubeconfig"
    path.write_text(merged)
    path.chmod(0o600)
    subprocess.run(["kubectl", "config", "use-context", contexts(lab)[0]], capture_output=True, timeout=15,
                   env={**os.environ, "KUBECONFIG": str(path)})
    return path


def rcfile(lab: str, config: Path) -> Path:
    meta = notebooks.DEMOS[lab]
    ctxs = contexts(lab)
    rc = _dir / f"{lab}.bashrc"
    rc.write_text(f"""
# Your own aliases and functions first (k, kgp, ns ...), then the lab on top.
[ -f "$HOME/.bash_profile" ] && . "$HOME/.bash_profile" >/dev/null 2>&1
# A lab shell never runs as the profile's default AWS account. Clear it before the lab
# environment loads: Build an agent then sets its own profile from .env.aws.
unset AWS_PROFILE AWS_ACCOUNT ECR_HOST
{notebooks.preamble(lab)}
export KUBECONFIG="{config}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.arctl/bin:$PATH"
export TERM=xterm-256color CLICOLOR=1 BASH_SILENCE_DEPRECATION_WARNING=1
# Prompt hooks from whatever launched the console (bash-preexec, terminal apps)
# are not defined in this shell, so drop them.
unset PROMPT_COMMAND PS0
PS1='\\[\\e[1;35m\\]{meta["short"]}\\[\\e[0m\\] \\[\\e[36m\\]$(kubectl config current-context 2>/dev/null)\\[\\e[0m\\] \\W \\$ '
printf '\\e[1m%s\\e[0m  kubectl is on \\e[36m%s\\e[0m' {meta["short"]!r} {ctxs[0]!r}
{"printf '  (also %s: kubectl --context %s)' " + repr(ctxs[1]) + " " + repr(ctxs[1]) if len(ctxs) > 1 else ""}
printf '\\n  This kubeconfig holds only this lab'"'"'s clusters. The lab environment is loaded.\\n\\n'
""")
    return rc


class Session:
    def __init__(self, lab: str):
        self.lab = lab
        self.id = secrets.token_hex(6)   # a page holding another id has stale offsets
        self.buf = bytearray()
        self.base = 0              # absolute offset of buf[0]
        self.cond = threading.Condition()
        self.alive = True
        config = kubeconfig(lab)
        rc = rcfile(lab, config)
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(notebooks.NOTEBOOKS)
            env = {k: v for k, v in os.environ.items() if k not in ("PROMPT_COMMAND", "PS0", "PS1")}
            os.execvpe("bash", ["bash", "--rcfile", str(rc), "-i"],
                       {**env, "TERM": "xterm-256color", "KUBECONFIG": str(config),
                        "BASH_SILENCE_DEPRECATION_WARNING": "1"})
        self.pid, self.fd = pid, fd
        self.resize(120, 30)
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        while True:
            try:
                ready, _, _ = select.select([self.fd], [], [], 1.0)
                if not ready:
                    if self._exited():
                        break
                    continue
                data = os.read(self.fd, 65536)
            except OSError:
                break
            if not data:
                break
            with self.cond:
                self.buf += data
                if len(self.buf) > BUFFER_MAX:
                    cut = len(self.buf) - BUFFER_MAX
                    del self.buf[:cut]
                    self.base += cut
                self.cond.notify_all()
        with self.cond:
            self.alive = False
            self.cond.notify_all()
        try:
            os.close(self.fd)
        except OSError:
            pass

    def _exited(self) -> bool:
        try:
            return os.waitpid(self.pid, os.WNOHANG)[0] != 0
        except ChildProcessError:
            return True

    def read_from(self, offset: int, timeout: float = 15.0) -> tuple[int, bytes, bool]:
        """Everything after offset, waiting up to timeout for something new."""
        with self.cond:
            end = self.base + len(self.buf)
            if offset >= end and self.alive:
                self.cond.wait(timeout)
                end = self.base + len(self.buf)
            start = max(offset, self.base)
            return end, bytes(self.buf[start - self.base:]), self.alive

    def write(self, data: bytes):
        if self.alive:
            os.write(self.fd, data)

    def resize(self, cols: int, rows: int):
        try:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
            os.kill(self.pid, signal.SIGWINCH)
        except OSError:
            pass

    def close(self):
        try:
            os.killpg(os.getpgid(self.pid), signal.SIGHUP)
        except OSError:
            pass


def session(lab: str, fresh: bool = False) -> Session:
    if lab not in notebooks.DEMOS:
        raise ValueError("Unknown lab")
    with _lock:
        s = _sessions.get(lab)
        if s and (fresh or not s.alive):
            s.close()
            s = None
        if s is None:
            s = _sessions[lab] = Session(lab)
        return s


def get(lab: str) -> Session | None:
    return _sessions.get(lab)


def allowed(headers, port: int) -> bool:
    """The page's token, and nothing from another site or a rebound hostname."""
    if headers.get("X-Term-Token") != TOKEN:
        return False
    hosts = {f"localhost:{port}", f"127.0.0.1:{port}"}
    if headers.get("Host") not in hosts:
        return False
    origin = headers.get("Origin")
    return origin is None or origin in {f"http://{h}" for h in hosts}


def token_for(headers, port: int) -> str | None:
    """The token again, for a page that outlived a console restart. Another site
    cannot read this response (no CORS headers), the Host check stops DNS
    rebinding, and a browser marks cross-site requests in Sec-Fetch-Site."""
    if headers.get("Host") not in {f"localhost:{port}", f"127.0.0.1:{port}"}:
        return None
    if headers.get("Sec-Fetch-Site") not in (None, "same-origin", "none"):
        return None
    return TOKEN


def dock(lab: str) -> str:
    """The collapsed terminal bar the lab pages carry."""
    ctx = contexts(lab)[0]
    return f"""<div class="term-dock" id="term-dock" data-lab="{lab}" data-token="{TOKEN}" hidden>
  <div class="term-bar">
    <button type="button" class="term-toggle" id="term-toggle" aria-expanded="false">
      <span class="term-caret">▸</span> Terminal <span class="term-ctx">{ctx}</span></button>
    <span class="term-hint"><kbd>`</kbd> toggle</span>
    <span class="term-actions">
      <button type="button" class="btn" id="term-new" title="Start a fresh shell">New shell</button>
      <button type="button" class="btn" id="term-max" title="Taller">↕</button>
    </span>
  </div>
  <div class="term-body" id="term-body"></div>
</div>"""


HEAD = ('  <link rel="stylesheet" href="/static/vendor/xterm/xterm.css">\n'
        '  <link rel="stylesheet" href="/static/css/terminal.css">\n')
SCRIPTS = ('<script src="/static/vendor/xterm/xterm.js"></script>'
           '<script src="/static/vendor/xterm/addon-fit.js"></script>'
           '<script src="/static/js/terminal.js"></script>')
