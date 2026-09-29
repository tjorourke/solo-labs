"""Presenter view for a notebook demo step.

The classic step page shows the notebook as written: every paragraph, and every
cell in full, colour variables and loops included. That is right for someone
following along, and too much text for an audience watching a projector.

A demo opts in with `present/<demo>.json`. For each step it holds:

    say     one line on what the step does
    point   what to point at once it has run
    blocks  one entry per notebook cell, in order:
              title   a label for the cell
              show    the one to three lines worth reading out, not the whole cell
              checks  rows that turn the cell's output into a verdict

Blocks can declare parts with exact shell boundaries, instructions and expected
results. Each part runs in a fresh lab environment. The Commands tab shows that
part's actual script, including any shell-state preparation. The browser sends
only demo, chapter, cell, part and revision identifiers to the server.

A check is `{label, match}` where `match` is a regex over the ANSI-stripped output.
Optional: `absent` (pass when it does NOT match), `from`/`to` (only search the text
between two markers), `value` (a regex whose first group is shown on the row),
`warn` (a miss is amber rather than red) and `save` (remember the value, so the App
tab can pick up the ingress address from §1.3).

A demo with a browsable app sets a top-level `app: {label, hint}`; the App tab reads
the address a check saved as `app`. Without it there is no App tab. The Gloo UI tab
appears when the demo has a `gloo-ui` console; other consoles stay buttons, since
most send X-Frame-Options and cannot be embedded.
"""
from __future__ import annotations

import hashlib
import html
import json
import re

import notebooks
from notebooks import ROOT, Demo, Step

PRESENT_DIR = ROOT / "present"


def spec(demo_id: str) -> dict | None:
    """Read on every request, so editing the JSON shows on the next reload."""
    path = PRESENT_DIR / f"{demo_id}.json"
    if not path.is_file():
        return None
    return json.loads(path.read_text())


def step_spec(demo_id: str, step_id: str) -> dict | None:
    s = spec(demo_id)
    return (s or {}).get("steps", {}).get(step_id)


def actions(demo: Demo, step: Step) -> list[dict]:
    """Split notebook cells at authored shell boundaries, never by line count.

    Each `start` must occur exactly once. `prepare` restores shell variables or
    functions for a new process; it must not repeat an earlier cluster change.
    """
    st = step_spec(demo.id, step.id) or {}
    result = []
    cells = [b for b in step.blocks if b.kind == "code"]
    for index, (cell, block) in enumerate(zip(cells, st.get("blocks", []), strict=True)):
        parts = block.get("parts") or [{}]
        starts = [0]
        for part in parts[1:]:
            marker = part["start"]
            hits = list(re.finditer("^" + re.escape(marker), cell.source, re.M))
            if len(hits) != 1 or hits[0].start() <= starts[-1]:
                raise ValueError(f"{demo.id}/{step.id}/{index}: ambiguous or moved boundary {marker!r}")
            starts.append(hits[0].start())
        starts.append(len(cell.source))
        for number, part in enumerate(parts):
            source = cell.source[starts[number]:starts[number + 1]].strip()
            colours = next((line for line in cell.source.splitlines() if line.startswith("GRN=")), "")
            prepare = "\n".join(x for x in (colours if number else "", part.get("prepare", "")) if x)
            checks = part.get("checks", block.get("checks", []) if len(parts) == 1 else [])
            checks = [block["checks"][c] if isinstance(c, int) else c for c in checks]
            script = "\n".join(x for x in (prepare, source) if x)
            item = {
                "index": index, "part": number, "source": source, "script": script,
                "title": part.get("title", block["title"]),
                "instruction": part.get("instruction", block.get("instruction", st.get("say", ""))),
                "expect": part.get("expect", block.get("expect", st.get("point", ""))),
                "checks": checks,
                "strict": part.get("strict", block.get("strict", True)),
                # Optional numeric inputs shown beside Run, e.g. how many turns to loop.
                "params": part.get("params", block.get("params", [])),
                # The workspace tab to show while it runs (default: Output).
                "watch": part.get("watch", block.get("watch", "output")),
            }
            item["revision"] = hashlib.sha256(json.dumps(item, sort_keys=True).encode()).hexdigest()[:16]
            result.append(item)
    return result


def action_script(demo: Demo, step: Step, index: int, part: int, revision: str, params: dict | None = None) -> str:
    action = next((a for a in actions(demo, step) if (a["index"], a["part"]) == (index, part)), None)
    if not action or action["revision"] != revision:
        raise ValueError("This step has changed. Reload the page before running it.")
    return ("set -eo pipefail\n" if action["strict"] else "") + _exports(action, params or {}) + action["script"]


class ParamError(ValueError):
    """A step parameter outside what the spec allows. Shown to the presenter."""


def _exports(action: dict, given: dict) -> str:
    """Only parameters the spec declares, only whole numbers inside their range.
    The browser sends a number, never shell; the server writes the export."""
    lines = []
    for p in action.get("params", []):
        raw = given.get(p["name"], p.get("default"))
        try:
            value = int(raw)
        except (TypeError, ValueError):
            raise ParamError(f"{p.get('label', p['name'])} must be a whole number")
        if not p.get("min", value) <= value <= p.get("max", value):
            raise ParamError(f"{p.get('label', p['name'])} must be between {p.get('min')} and {p.get('max')}")
        lines.append(f"export {p['name']}={value}\n")
    return "".join(lines)


def view(demo: Demo, step: Step) -> str | None:
    """The presenter page for a story step, or None when the demo has no spec."""
    s = spec(demo.id)
    if not s or step.id not in s.get("steps", {}) or step not in demo.story:
        return None
    return page(demo, step, s)


def _e(s: str) -> str:
    return html.escape(s or "", quote=True)


def _fix_details(h: str) -> str:
    """The markdown renderer treats a raw <details> line as a figure, so it opens
    in one div and closes in another. Browsers repair that by closing the guide
    column early, which drops the stage onto a second grid row."""
    h = re.sub(r'<div class="nb-figure">\s*<details>', '<details class="pr-more">', h)
    h = re.sub(r'(</summary>)\s*</div>', r'\1', h)
    return re.sub(r'<div class="nb-figure">\s*</details>\s*</div>', '</details>', h)


def _rail(demo: Demo, step: Step, s: dict, ntabs: int) -> str:
    items = []
    for st in demo.story:
        cls = "on" if st.id == step.id else ""
        items.append(
            f'<li class="{cls}" data-step="{_e(st.id)}"><a href="/{demo.id}/{_e(st.id)}">'
            f'<i class="tick"></i><span class="n">{_e(st.num)}</span>'
            f'<span class="t">{_e(s["steps"].get(st.id, {}).get("short") or st.title)}</span></a></li>'
        )
    return f"""<aside class="pr-rail">
    <a class="pr-back" href="/{demo.id}">← {_e(demo.title)}</a>
    <div class="pr-progress"><span id="pr-bar"></span></div>
    <div class="pr-progress-label" id="pr-count"></div>
    <ol class="pr-steps">{''.join(items)}</ol>
    <div class="pr-keys">
      <kbd>←</kbd><kbd>→</kbd> chapter &nbsp; <kbd>Enter</kbd> run step<br>
      <kbd>N</kbd> notes &nbsp; <kbd>1</kbd>–<kbd>{ntabs}</kbd> tabs &nbsp; <kbd>F</kbd> full screen
    </div>
  </aside>"""


def _cmd(demo: Demo, step: Step, i: int, b: dict, total: int) -> str:
    label = b["title"]
    checks = json.dumps(b.get("checks") or [])
    return f"""<div class="pr-cmd" data-demo="{_e(demo.id)}" data-step="{_e(step.id)}" data-index="{b['index']}" data-part="{b['part']}" data-revision="{b['revision']}" data-checks="{_e(checks)}" data-watch="{_e(b.get('watch', 'output'))}">
      <button class="pr-cmd-head" type="button" aria-expanded="{'true' if i == 0 else 'false'}" aria-controls="action-{i}">
        <span class="pr-cmd-n">{i + 1}</span>
        <span class="pr-cmd-title">{_e(label)}</span>
        <span class="pr-state" hidden></span>
      </button>
      <div class="pr-cmd-body" id="action-{i}"{' hidden' if i else ''}>
      <p class="pr-instruction">{_e(b['instruction'])}</p>
      <p class="pr-expect"><b>Expected result</b>{_e(b['expect'])}</p>
      <div class="pr-cmd-btns">
        {_params(b)}<button class="btn primary pr-go" type="button">Run step {i + 1}</button>
        <button class="btn pr-code" type="button">Commands</button>
        <button class="btn pr-stop" type="button" disabled>Stop</button>
      </div>
      </div>
    </div>"""


def _helpers(demo: Demo, b: dict) -> str:
    used = notebooks.helpers_for(demo.id, b["script"])
    if not used:
        return ""
    files = sorted({f for _, f, _ in used})
    body = "\n\n".join(f"# {name}  ({f})\n{src}" for name, f, src in used)
    return (f'<div class="pr-helpers"><div class="pr-helpers-head">What the helpers in this step run '
            f'<span>({_e(", ".join(files))})</span></div><pre><code>{_e(body)}</code></pre></div>')


def _params(b: dict) -> str:
    return "".join(
        f'<label class="pr-param">{_e(p.get("label", p["name"]))}'
        f'<input type="number" data-param="{_e(p["name"])}" min="{p.get("min", "")}" max="{p.get("max", "")}" '
        f'value="{p.get("default", "")}" step="1"></label>'
        for p in b.get("params", []))


def page(demo: Demo, step: Step, s: dict) -> str:
    import lab_reset
    st = s["steps"][step.id]
    blocks = actions(demo, step)
    order = demo.story
    idx = order.index(step)
    prev_s = order[idx - 1] if idx > 0 else None
    next_s = order[idx + 1] if idx < len(order) - 1 else None

    cmds = "\n".join(_cmd(demo, step, i, b, len(blocks)) for i, b in enumerate(blocks))
    if not blocks:
        cmds = '<p class="pr-nothing">Reference chapter. Review the notes, then mark it complete.</p><button class="btn primary" id="pr-read" type="button">Mark as read</button>'

    notes = notebooks.render_markdown(st.get("notes", st.get("point", "")))
    figures = "\n".join(re.findall(r'<svg\b.*?</svg>', "\n".join(b.html for b in step.blocks if b.kind == "md"), re.S))
    scripts = "\n".join(
        f'<div class="pr-script" data-script="{i}"{" hidden" if i else ""}><div class="pr-script-head">Step {i + 1}: {_e(b["title"])}'
        f'<button class="btn pr-copy" type="button">Copy</button></div>'
        f'<pre><code>{_e(notebooks.expand_for_display(demo.id, b["script"]))}</code></pre>{_helpers(demo, b)}</div>'
        for i, b in enumerate(blocks)
    )

    pager = []
    if prev_s:
        pager.append(f'<a class="btn" id="pr-prev" href="/{demo.id}/{_e(prev_s.id)}">← {_e(prev_s.num)}</a>')
    if next_s:
        pager.append(f'<a class="btn primary" id="pr-next" href="/{demo.id}/{_e(next_s.id)}">'
                     f'{_e(next_s.num)} {_e(s["steps"].get(next_s.id, {}).get("short") or next_s.title)} →</a>')

    consoles = notebooks.consoles(demo.id)
    gloo = next((c for c in consoles if c["id"] == "gloo-ui"), None)
    others = "".join(
        f'<button class="btn nb-console" type="button" data-demo="{_e(demo.id)}" '
        f'data-console="{_e(c["id"])}">{_e(c["label"])} ↗</button>'
        for c in consoles if c is not gloo
    )
    tabs = [("result", "Checks"), ("output", "Output"), ("script", "Commands")]
    if figures:
        tabs.append(("diagram", "Diagram"))
    if gloo:
        tabs.append(("gloo", "Gloo UI"))
    app = s.get("app")
    if app:
        tabs.append(("app", "App"))
    tab_btns = "".join(
        f'<button type="button" data-tab="{t}" role="tab" aria-selected="{"true" if t == "result" else "false"}" aria-controls="pane-{t}"{" class=on" if t == "result" else ""}>'
        f'<span class="k">{n + 1}</span>{label}</button>'
        for n, (t, label) in enumerate(tabs)
    )
    gloo_pane = ""
    if gloo:
        gloo_pane = f"""<div class="pr-pane" data-pane="gloo" hidden>
        <div class="pr-frame-bar"><span>Gloo UI</span>
          <a href="{_e(gloo['url'])}" target="_blank" rel="noreferrer">open in a tab ↗</a></div>
        <iframe class="pr-frame" data-src="{_e(gloo['url'])}" data-demo="{_e(demo.id)}" data-console="gloo-ui" title="Gloo UI"></iframe>
      </div>"""

    app_pane = ""
    if app:
        app_pane = f"""<div class="pr-pane" data-pane="app" hidden>
      <div class="pr-frame-bar"><span id="pr-app-label">{_e(app.get("label", "App"))}</span>
        <span><button class="btn" type="button" id="pr-app-reload">Refresh</button>
        <a id="pr-app-open" href="#" target="_blank" rel="noreferrer">open in a tab ↗</a></span></div>
      <iframe class="pr-frame" id="pr-app" title="App" data-url="{_e(app.get("url", ""))}"></iframe>
      <p class="pr-empty" id="pr-app-empty">{_e(app.get("hint", ""))}</p>
    </div>"""

    body = f"""
<div class="pr" data-demo="{_e(demo.id)}" data-step="{_e(step.id)}" data-generation="{lab_reset.GENERATIONS[demo.id]}" data-story="{_e(json.dumps([x.id for x in order]))}">
  {_rail(demo, step, s, len(tabs))}

  <section class="pr-guide">
    <div class="pr-eyebrow">Chapter {idx + 1} of {len(order)}</div>
    <h1>{_e(st.get('title', step.title))}</h1>
    <p class="pr-say">{_e(st.get("say", ""))}</p>
    <div class="pr-run-controls"><span id="pr-action-count" aria-live="polite"></span>{'<button class="btn" id="pr-run-all" type="button">Run all steps</button>' if len(blocks) > 1 else ''}</div>
    {cmds}
    <p class="pr-run-message" id="pr-run-message" role="status"></p>
    <details class="pr-notes" id="pr-notes"><summary>Background <kbd>N</kbd></summary>
      <div class="nb-md">{notes}</div>
    </details>
    <div class="pr-pager">{''.join(pager)}</div>
    {lab_reset.control(demo.id) if next_s is None else ''}
    <div class="pr-links">{others}<p class="console-msg" id="console-msg"></p></div>
  </section>

  <section class="pr-stage">
    <div class="pr-tabs" role="tablist" aria-label="Lab workspace">{tab_btns}</div>
    <div class="pr-pane" data-pane="diagram" hidden><div class="pr-diagram" id="pr-diagram">{figures}</div></div>
    <div class="pr-pane" data-pane="result"><div id="pr-result"><p class="pr-empty">Run a step to check its result.</p></div></div>
    <div class="pr-pane" data-pane="output" hidden><pre class="log pr-out" id="pr-out"><span class="pr-empty">Nothing run yet.</span></pre></div>
    <div class="pr-pane" data-pane="script" hidden>
      <p class="pr-script-note">Commands for the selected step, with the lab's variables shown at their current values. The console supplies the cluster context and lab environment.</p>
      {scripts}
    </div>
    {gloo_pane}
    {app_pane}
  </section>
</div>
"""
    import terminal
    return notebooks.shell(
        st.get("title", step.title), body + terminal.dock(demo.id), active=f"/{demo.id}",
        extra_head='  <link rel="stylesheet" href="/static/css/present.css">\n' + terminal.HEAD,
        scripts='<script src="/static/js/notebook.js"></script>\n'
                '<script src="/static/js/present.js"></script><script src="/static/js/lab-reset.js"></script>'
                + terminal.SCRIPTS,
    )
