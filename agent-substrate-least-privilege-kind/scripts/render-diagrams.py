#!/usr/bin/env python3
"""Render the Mermaid sources offline with the installed gstack browser bundle.

Authoring only; running the Kubernetes lab does not require gstack.
Set GSTACK_ROOT if it is installed somewhere other than ~/.claude/skills/gstack.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

lab = Path(__file__).resolve().parents[1]
gstack = Path(os.environ.get('GSTACK_ROOT', Path.home() / '.claude/skills/gstack'))
browser = gstack / 'browse/dist/browse'
bundle = gstack / 'lib/diagram-render/dist/diagram-render.html'
if not browser.is_file() or not bundle.is_file():
    raise SystemExit('Diagram authoring requires the offline gstack browse/diagram-render bundle; set GSTACK_ROOT')
temp = lab / '.runtime'
temp.mkdir(exist_ok=True)
staged = temp / ('diagram-render-' + hashlib.sha256(bundle.read_bytes()).hexdigest()[:16] + '.html')
shutil.copyfile(bundle, staged)

def browse(*args):
    p = subprocess.run([str(browser)] + list(args), capture_output=True, text=True)
    if p.returncode:
        raise RuntimeError(p.stdout + p.stderr)
    return p.stdout

tab = str(json.loads(browse('newtab', '--json'))['tabId'])
try:
    browse('load-html', str(staged), '--tab-id', tab)
    browse('wait', '#done', '--tab-id', tab)
    for source in sorted((lab / 'diagrams').glob('*.mmd')):
        encoded = base64.b64encode(source.read_bytes()).decode()
        text = f"decodeURIComponent(escape(atob('{encoded}')))"
        browse('js', '--tab-id', tab, f"window.__renderMermaid('diagram-{source.stem}', {text}).then(s => {{window.__svg=s; return s.length}})")
        browse('js', '--tab-id', tab, 'window.__svg', '--out', str(source.with_suffix('.svg')))
        browse('js', '--tab-id', tab, 'window.__rasterize(window.__svg, 1950)', '--out', str(source.with_suffix('.png')))
        browse('js', '--tab-id', tab, f"window.__mermaidToExcalidraw({text}).then(j=>{{window.__scene=j;return 'ready'}})")
        browse('js', '--tab-id', tab, 'window.__scene', '--out', str(source.with_suffix('.excalidraw')))
        print(source.stem)
finally:
    browse('closetab', tab)
