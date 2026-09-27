"""Designed architecture illustration. One layout emits SVG and editable shapes.

Coordinates are intentional: connectors run in gutters, never through a card.
The before/after panel is an illustrated chapter-5 outcome, not live telemetry.
"""
import html
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent
INK, MUTED, PURPLE = "#172033", "#58657c", "#7c3aed"
BLUE, RED, GREEN = "#2563eb", "#be3455", "#087f5b"
PAPER = "#f6f7fc"


class Drawing:
    def __init__(self):
        self.svg, self.elements, self.group = [], [], None

    def element(self, kind, x, y, w, h, fill="transparent", stroke="transparent", **extra):
        n = len(self.elements) + 1
        obj = dict(id=f"defence-{n:03}", type=kind, x=x, y=y, width=max(w, 0), height=max(h, 0),
                   angle=0, strokeColor=stroke, backgroundColor=fill, fillStyle="solid",
                   strokeWidth=1.5, strokeStyle="solid", roughness=0, opacity=100,
                   groupIds=[self.group] if self.group else [], frameId=None, roundness=None,
                   seed=n, version=1, versionNonce=n, isDeleted=False, boundElements=None,
                   updated=1, link=None, locked=False)
        obj.update(extra)
        self.elements.append(obj)

    def begin(self, name):
        self.group = name
        self.svg.append(f'<g data-node="{name}">')

    def end(self):
        self.group = None
        self.svg.append('</g>')

    def rect(self, x, y, w, h, fill, stroke="none", r=12, *, shadow=False, node=False):
        attrs = (' filter="url(#defence-shadow)"' if shadow else '')
        attrs += (' data-node-box="true"' if node else '')
        self.svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="1.3"{attrs}/>')
        self.element("rectangle", x, y, w, h, "#2b2056" if fill.startswith("url(") else "transparent" if fill == "none" else fill,
                     "transparent" if stroke == "none" else stroke, roundness={"type": 3} if r else None)

    def text(self, x, y, text, size=20, colour=INK, weight=400, *, anchor="start", mono=False, spacing=None):
        family = "Menlo, Consolas, monospace" if mono else "Arial, sans-serif"
        extra = f' letter-spacing="{spacing}"' if spacing else ''
        self.svg.append(f'<text x="{x}" y="{y}" font-family="{family}" font-size="{size}" font-weight="{weight}" fill="{colour}" text-anchor="{anchor}"{extra}>{html.escape(text)}</text>')
        width = len(text) * size * (0.6 if mono else 0.55)
        left = x - (width if anchor == "end" else width / 2 if anchor == "middle" else 0)
        self.element("text", left, y-size, width, size*1.25, stroke=colour,
                     text=text, originalText=text, fontSize=size, fontFamily=3 if mono else 2,
                     textAlign="center" if anchor == "middle" else "right" if anchor == "end" else "left",
                     verticalAlign="top", containerId=None, autoResize=True, lineHeight=1.25)

    def circle(self, x, y, r, fill, stroke="none", width=1.5):
        self.svg.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{width}"/>')
        self.element("ellipse", x-r, y-r, r*2, r*2, "transparent" if fill == "none" else fill, "transparent" if stroke == "none" else stroke)

    def path(self, points, colour, width=2, *, arrow=False, dash=False, fill="none", connector=False):
        d = "M" + " L".join(f"{x},{y}" for x, y in points)
        attrs = ' marker-end="url(#defence-arrow)"' if arrow else ''
        attrs += ' stroke-dasharray="6 6"' if dash else ''
        attrs += ' data-connector="true"' if connector else ''
        self.svg.append(f'<path d="{d}" fill="{fill}" stroke="{colour}" stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round"{attrs}/>')
        x, y = min(p[0] for p in points), min(p[1] for p in points)
        w, h = max(p[0] for p in points)-x, max(p[1] for p in points)-y
        self.element("arrow" if arrow else "line", x, y, w, h,
                     "transparent" if fill == "none" else fill, colour,
                     points=[[a-x, b-y] for a, b in points], strokeWidth=width,
                     strokeStyle="dashed" if dash else "solid", startBinding=None, endBinding=None,
                     startArrowhead=None, endArrowhead="triangle" if arrow else None,
                     lastCommittedPoint=None)

    def badge(self, x, y, w, label, bg, fg, size=15):
        self.rect(x, y, w, 28, bg, r=7)
        self.text(x+w/2, y+19, label, size, fg, 700, anchor="middle")

    def number(self, x, y, label, bg, fg):
        self.circle(x, y, 13, bg)
        self.text(x, y+5, label, 14, fg, 700, anchor="middle")


def build():
    d = Drawing()
    d.rect(0, 0, 960, 900, PAPER, r=20)
    d.rect(0, 0, 960, 120, "#101426", r=20)
    d.rect(0, 90, 960, 30, "#101426", r=0)
    d.text(32, 34, "SOLO / INCIDENT RESPONSE", 13, "#c4b5fd", 700, spacing=2)
    d.text(32, 74, "Layers of defence", 36, "#ffffff", 700)
    d.text(32, 103, "Where the agent's permissions are enforced", 20, "#cbd5e1")
    # The console's Solo mark, on the same navy background as its navigation.
    mark = [(808, 30), (794, 44), (822, 44), (808, 58)]
    for a, b in [(0, 1), (0, 2), (1, 2), (1, 3), (2, 3)]:
        d.path([mark[a], mark[b]], "#a78bfa", 1.8)
    for p in mark:
        d.circle(*p, 4, "#a78bfa")
    d.text(838, 51, "SOLO.IO", 19, "#ffffff", 700, spacing=1)
    d.badge(842, 76, 86, "mesh1", "#272c46", "#d8ddec", 16)

    d.begin("request")
    d.rect(32, 144, 896, 52, "#ffffff", "#dce1ed", node=True)
    d.circle(62, 161, 6, "none", MUTED, 1.8)
    d.path([(51, 184), (51, 181), (55, 174), (69, 174), (73, 181), (73, 184)], MUTED, 1.8)
    d.text(94, 177, "Investigate the payments outage", 22, INK)
    d.text(470, 176, "front door", 15, MUTED, 700)
    d.number(574, 170, "04", "#ede9fe", "#5b21b6")
    d.text(594, 176, "Signed caller", 17, "#5b21b6", 700)
    d.number(748, 170, "07", "#ede9fe", "#5b21b6")
    d.text(768, 176, "Rate per caller", 17, "#5b21b6", 700)
    d.end()

    # Draw the trust-boundary background before the admitted MCP connection.
    d.rect(674, 366, 270, 180, "#edf4ff", "#9dbdf6", r=16)
    d.rect(685, 350, 247, 30, PAPER, r=5)
    d.number(700, 365, "03", "#dbeafe", BLUE)
    d.text(722, 371, "WORKLOAD IDENTITY", 14, "#1d4ed8", 700, spacing=.3)

    # All flow lines are laid out in clear gutters before drawing the cards.
    d.path([(284, 302), (340, 302)], "#776b9f", 2.4, arrow=True, connector=True)
    d.text(312, 290, "calls", 15, MUTED, anchor="middle")
    d.path([(612, 286), (680, 286)], "#776b9f", 2.4, arrow=True, connector=True)
    d.text(646, 272, "LLM", 15, MUTED, 700, anchor="middle")
    d.path([(612, 452), (680, 452)], "#776b9f", 2.4, arrow=True, connector=True)
    d.text(646, 438, "MCP", 15, MUTED, 700, anchor="middle")
    d.path([(156, 380), (156, 418)], "#776b9f", 2, arrow=True, connector=True)
    d.text(176, 408, "outside check", 15, MUTED)
    d.path([(284, 354), (314, 354), (314, 580), (638, 580)], RED, 2, dash=True, connector=True)
    d.text(362, 567, "Direct MCP call", 18, RED, 700)
    d.circle(653, 580, 12, "#fff1f2", RED, 2)
    d.path([(648, 575), (658, 585)], RED, 2.3)
    d.path([(658, 575), (648, 585)], RED, 2.3)
    d.text(679, 586, "REFUSED BY ISTIO", 15, RED, 700, spacing=.5)

    d.begin("agent")
    d.rect(32, 226, 250, 152, "#ffffff", "#dcd5ee", shadow=True, node=True)
    d.rect(50, 246, 42, 42, "#f0eaff", r=10)
    d.rect(57, 257, 28, 22, "none", PURPLE, r=6)
    d.path([(71, 250), (71, 257)], PURPLE, 1.8)
    d.circle(71, 250, 2.4, PURPLE)
    d.circle(65, 266, 2, PURPLE)
    d.circle(77, 266, 2, PURPLE)
    d.path([(65, 273), (77, 273)], PURPLE, 1.8)
    d.text(105, 275, "kagent", 29, "#362164", 700)
    d.text(52, 314, "Incident-response agent", 20, INK)
    d.badge(52, 332, 171, "Declarative Agent", "#f0eaff", "#6d28d9", 16)
    d.end()

    d.begin("gateway")
    d.rect(352, 226, 258, 316, "url(#defence-gateway-fill)", "#5b4691", shadow=True, node=True)
    d.path([(388, 246), (404, 252), (404, 264), (400, 273), (388, 283), (376, 273), (372, 264), (372, 252), (388, 246)], "#c4b5fd", 1.8)
    d.path([(382, 263), (387, 268), (395, 257)], "#ddd6fe", 2.2)
    d.text(418, 270, "agentgateway", 25, "#ffffff", 700)
    d.text(418, 296, "Mesh waypoint", 18, "#c4b5fd")
    for y, number, label in [(310, "05", "Tool permissions"), (353, "06", "Personal data")]:
        d.rect(370, y, 222, 36, "#3f3269", r=8)
        d.number(391, y+18, number, "#5d478d", "#f0eaff")
        d.text(414, y+25, label, 20, "#ffffff", 500)
    for y, label in [(396, "Holds the provider key"), (439, "Agent holds no token")]:
        d.rect(370, y, 222, 36, "#2e2552", r=8)
        d.text(384, y+24, label, 17, "#ded7ef")
    d.path([(374, 491), (589, 491)], "#5a4b7c", 1)
    d.number(391, 514, "08", "#3e355f", "#d5cce9")
    d.text(414, 521, "Logs + metrics", 18, "#ded7ef")
    d.end()

    d.begin("claude")
    d.rect(692, 226, 236, 120, "#fffaf5", "#ead9cb", shadow=True, node=True)
    for i in range(12):
        a = i * math.pi / 6
        d.path([(724+5*math.cos(a), 261+5*math.sin(a)),
                (724+16*math.cos(a), 261+16*math.sin(a))], "#c56b45", 2.6)
    d.text(754, 270, "Claude", 27, "#643923", 700)
    d.text(712, 310, "Haiku 4.5", 22, INK)
    d.text(907, 333, "Anthropic", 15, "#946e56", anchor="end")
    d.end()

    d.begin("tools")
    d.rect(692, 386, 236, 142, "#ffffff", "#c9d7ed", shadow=True, node=True)
    for y in [405, 416, 427]:
        d.rect(712, y, 30, 8, "#ede9fe", "#a78bfa", r=2)
        d.circle(718, y+4, 1.4, PURPLE)
    d.text(754, 429, "kagent", 26, "#362164", 700)
    d.text(712, 467, "Incident tools", 23, INK)
    d.text(712, 503, "MCPServer", 17, MUTED, mono=True)
    d.end()

    d.begin("egress")
    d.rect(32, 430, 250, 112, "#eff6ff", "#c4d7f5", node=True)
    d.path([(53, 469), (65, 445), (65, 469), (53, 469)], BLUE, 1, fill="#60a5fa")
    d.path([(69, 450), (78, 469), (69, 469), (69, 450)], BLUE, 1, fill="#2563eb")
    d.path([(50, 475), (80, 475), (75, 480), (55, 480), (50, 475)], BLUE, 1, fill="#2563eb")
    d.text(96, 471, "Istio egress", 23, "#1e40af", 700)
    d.number(253, 449, "02", "#dbeafe", BLUE)
    d.text(52, 515, "example.com is refused", 19, "#365a8c")
    d.end()

    d.text(32, 631, "Ask the agent to close every incident", 26, INK, 700)
    d.text(32, 658, "Closing the record does not resolve the fault.", 20, MUTED)

    d.begin("before")
    d.rect(32, 680, 436, 166, "#fff5f6", "#f0bdc9", node=True)
    d.text(52, 708, "WITHOUT A TOOL POLICY", 14, "#a82e4b", 700, spacing=.8)
    d.text(52, 760, "0", 44, INK, 700)
    d.text(85, 755, "open", 22, MUTED)
    d.path([(216, 727), (216, 768)], "#eccbd3", 1)
    d.text(244, 760, "3", 44, RED, 700)
    d.text(279, 755, "closed", 22, RED)
    d.text(52, 804, "3 faults still unresolved", 22, "#9f2946", 700)
    d.text(52, 831, "Bulk close succeeded", 17, "#9f6270")
    d.end()

    d.begin("after")
    d.rect(492, 680, 436, 166, "#effbf5", "#a6dac1", node=True)
    d.text(512, 708, "WITH A READ-ONLY POLICY", 14, "#087f5b", 700, spacing=.8)
    d.text(512, 760, "3", 44, GREEN, 700)
    d.text(547, 755, "open", 22, GREEN)
    d.badge(741, 731, 166, "WRITE REFUSED", "#d0f0df", "#086b4e", 15)
    d.text(512, 804, "Read-only tools still work", 22, "#086b4e", 700)
    d.text(512, 831, "Bulk close refused", 17, "#46735f")
    d.end()
    d.text(32, 881, "Illustrated chapter-5 outcome. Live incident records and evidence are in the App tab.", 16, MUTED)

    defs = '''<defs>
      <linearGradient id="defence-gateway-fill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#382763"/><stop offset="1" stop-color="#231c40"/></linearGradient>
      <filter id="defence-shadow" x="-15%" y="-15%" width="130%" height="140%"><feDropShadow dx="0" dy="5" stdDeviation="6" flood-color="#232142" flood-opacity=".09"/></filter>
      <marker id="defence-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M1 1 L9 5 L1 9 Z" fill="#776b9f"/></marker>
    </defs>'''
    svg = '<svg id="defence-architecture" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 900" width="100%" role="img" aria-labelledby="defence-title defence-desc">\n'
    svg += '<title id="defence-title">Layers of defence for a kagent incident-response agent</title>\n'
    svg += '<desc id="defence-desc">kagent runs the agent and incident MCP tools. People reach the agent through a front door gateway that requires a signed caller and limits requests per caller. The agent reaches Claude and its tools through an agentgateway waypoint that identifies it by SPIFFE identity, enforces tool permissions and the personal-data guard, and holds the provider key. Istio refuses direct tool access and example.com egress. Before the tool policy, three unresolved incidents are closed. After the policy, the bulk close is refused and investigation remains available.</desc>\n'
    svg += defs + '\n' + '\n'.join(d.svg) + '\n</svg>\n'
    (ROOT / 'architecture.svg').write_text(svg)
    (ROOT / 'architecture.excalidraw').write_text(json.dumps({
        "type": "excalidraw", "version": 2, "source": "solo-demos/vision-demo-2026",
        "elements": d.elements, "appState": {"viewBackgroundColor": "#ffffff", "gridSize": None}, "files": {}
    }, indent=2) + '\n')
    print(f"Designed SVG and {len(d.elements)} editable elements")


if __name__ == '__main__':
    build()
