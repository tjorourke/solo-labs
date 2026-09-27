"""Build the designed SVG/editable scene and rasterise it with the offline bundle."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
from design import build

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
    build()
    data = BUNDLE.read_bytes()
    staged = Path("/tmp") / ("gstack-diagram-render-" + hashlib.sha256(data).hexdigest()[:16] + ".html")
    if not staged.exists():
        staged.write_bytes(data)
    tab = str(json.loads(browse("newtab", "--json"))["tabId"])
    try:
        print(browse("load-html", str(staged), "--tab-id", tab))
        browse("wait", "#done", "--tab-id", tab)
        source = base64.b64encode((ROOT / "architecture.svg").read_bytes()).decode()
        print(browse("js", "--tab-id", tab,
                     f"window.__svg=atob('{source}'); 'Designed SVG ready'"))
        print(browse("js", "--tab-id", tab, '''(() => {
          const holder = document.createElement('div');
          holder.style.width = '960px'; holder.innerHTML = window.__svg;
          document.body.appendChild(holder);
          const svg = holder.querySelector('svg'), errors = [];
          const boxes = [...svg.querySelectorAll('[data-node-box]')].map(r => r.getBBox());
          const inside = (p, b, pad=0) => p.x > b.x+pad && p.x < b.x+b.width-pad && p.y > b.y+pad && p.y < b.y+b.height-pad;
          for (const group of svg.querySelectorAll('[data-node]')) {
            const box = group.querySelector('[data-node-box]').getBBox();
            for (const text of group.querySelectorAll('text')) {
              const b = text.getBBox();
              if (b.x < box.x || b.y < box.y || b.x+b.width > box.x+box.width || b.y+b.height > box.y+box.height)
                errors.push('Label outside '+group.dataset.node+': '+text.textContent);
            }
          }
          for (const path of svg.querySelectorAll('[data-connector]')) {
            for (let n=0; n<=path.getTotalLength(); n+=1) {
              if (boxes.some(b => inside(path.getPointAtLength(n), b, 1))) {
                errors.push('Connector crosses a card'); break;
              }
            }
          }
          const vb = svg.viewBox.baseVal;
          for (const text of svg.querySelectorAll('text')) {
            const b = text.getBBox();
            if (b.x < 0 || b.y < 0 || b.x+b.width > vb.width || b.y+b.height > vb.height)
              errors.push('Label outside viewBox: '+text.textContent);
          }
          if (errors.length) throw new Error(errors.join('; '));
          return {cards:boxes.length, labels:svg.querySelectorAll('text').length, clippedLabels:0, connectorCrossings:0};
        })()'''))
        browse("js", "--tab-id", tab, "window.__rasterize(window.__svg, 1920)", "--out", str(ROOT / "architecture.png"))
    finally:
        browse("closetab", tab)


if __name__ == "__main__":
    main()
