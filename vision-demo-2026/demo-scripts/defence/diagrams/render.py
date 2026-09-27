"""Render the editable architecture and notebook SVG using the offline gstack bundle."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
GSTACK = Path.home() / ".claude/skills/gstack"
BROWSE = GSTACK / "browse/dist/browse"
BUNDLE = GSTACK / "lib/diagram-render/dist/diagram-render.html"


def browse(*args):
    p = subprocess.run([str(BROWSE), *args], cwd=ROOT,
                       capture_output=True, text=True, timeout=120)
    if p.returncode:
        raise RuntimeError(p.stderr.strip() or p.stdout.strip())
    return p.stdout.strip()


def main():
    data = BUNDLE.read_bytes()
    staged = Path("/tmp") / ("gstack-diagram-render-" + hashlib.sha256(data).hexdigest()[:16] + ".html")
    if not staged.exists():
        staged.write_bytes(data)
    tab = str(json.loads(browse("newtab", "--json"))["tabId"])
    try:
        print(browse("load-html", str(staged), "--tab-id", tab))
        browse("wait", "#done", "--tab-id", tab)
        source = base64.b64encode((ROOT / "architecture.mmd").read_bytes()).decode()
        text = f"atob('{source}')"
        print(browse("js", "--tab-id", tab,
                     f"window.__renderMermaid('defence-architecture', {text}).then(s => {{window.__svg=s.replace('<svg ', '<svg font-family=\"Arial, sans-serif\" ');return 'SVG ready'}})"))
        browse("js", "--tab-id", tab, "window.__svg", "--out", str(ROOT / "architecture.svg"))
        browse("js", "--tab-id", tab, "window.__rasterize(window.__svg, 1950)", "--out", str(ROOT / "architecture.png"))
        print(browse("js", "--tab-id", tab,
                     f"window.__mermaidToExcalidraw({text}).then(s => {{window.__scene=s;return 'Editable scene ready'}})"))
        browse("js", "--tab-id", tab, "window.__scene", "--out", str(ROOT / "architecture.excalidraw"))
    finally:
        browse("closetab", tab)


if __name__ == "__main__":
    main()
