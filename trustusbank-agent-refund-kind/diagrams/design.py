"""Generate the bank architecture as SVG and editable Excalidraw shapes."""
import html
import json
from pathlib import Path

ROOT = Path(__file__).parent
INK, MUTED, PURPLE = '#172033', '#58657c', '#7c3aed'
elements, shapes, boxes, connectors = [], [], {}, []


def element(kind, x, y, w, h, **extra):
    n = len(elements) + 1
    e = dict(id=f'bank-{n}', type=kind, x=x, y=y, width=w, height=h, angle=0,
             strokeColor=INK, backgroundColor='transparent', fillStyle='solid',
             strokeWidth=2, strokeStyle='solid', roughness=0, opacity=100,
             groupIds=[], frameId=None, roundness=None, seed=n, version=1,
             versionNonce=n, isDeleted=False, boundElements=None, updated=1,
             link=None, locked=False)
    e.update(extra)
    elements.append(e)


def text(x, y, value, size=19, colour=INK, weight=400):
    shapes.append(f'<text x="{x}" y="{y}" text-anchor="middle" font-size="{size}" font-weight="{weight}" fill="{colour}">{html.escape(value)}</text>')
    width = len(value) * size * .54
    element('text', x-width/2, y-size, width, size*1.3, text=value,
            originalText=value, fontSize=size, fontFamily=2, textAlign='center',
            verticalAlign='top', containerId=None, autoResize=True, lineHeight=1.3,
            strokeColor=colour)


def box(name, x, y, w, h, lines, colour='#fff', stroke='#d5dbea'):
    boxes[name] = (x, y, w, h)
    shapes.append(f'<g data-node="{name}"><rect data-node-box="true" x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{colour}" stroke="{stroke}" stroke-width="2"/>')
    element('rectangle', x, y, w, h, backgroundColor=colour, strokeColor=stroke,
            roundness={'type': 3})
    start = y + h/2 - (len(lines)-1)*13 + 7
    for index, line in enumerate(lines):
        text(x+w/2, start+index*26, line, 19 if index == 0 else 16,
             INK if index == 0 else MUTED, 700 if index == 0 else 400)
    shapes.append('</g>')


def edge(points, dashed=False, colour='#8b98b0'):
    connectors.append(points)
    d = 'M' + ' L'.join(f'{x},{y}' for x, y in points)
    dash = 'stroke-dasharray="7 5"' if dashed else ''
    shapes.append(f'<path data-connector="true" d="{d}" fill="none" stroke="{colour}" stroke-width="2" {dash} marker-end="url(#arrow)"/>')
    x, y = points[0]
    element('arrow', x, y, max(p[0] for p in points)-x, max(p[1] for p in points)-y,
            points=[[a-x, b-y] for a, b in points], startBinding=None, endBinding=None,
            startArrowhead=None, endArrowhead='triangle', lastCommittedPoint=None,
            strokeColor=colour, strokeStyle='dashed' if dashed else 'solid')


def build():
    text(837, 42, 'TrustUs Bank · customer refunds', 29, INK, 700)
    text(837, 75, 'Five declarative agents. Identity checks and credentials stay at the gateways.', 19, MUTED)
    box('carol', 25, 225, 170, 80, ['Carol', 'customer-service'], '#eef5ff')
    box('bob', 25, 380, 170, 80, ['Bob', 'payments-ops'], '#eef5ff')
    box('alice', 25, 565, 170, 80, ['Alice', 'security-ops'], '#fff4ec')
    box('keycloak', 240, 110, 180, 80, ['Keycloak', 'bank realm'])
    box('ui', 240, 225, 180, 235, ['Solo UI', 'OIDC sign-in', 'Chat · policies', 'Traces'], '#f4efff')
    box('switch', 240, 565, 180, 80, ['AccessPolicy', 'DENY refunds-agent'], '#fff4ec')
    box('service', 460, 215, 210, 100, ['Customer service', 'assistant + waypoint', 'Read only'], '#f4efff')
    box('payments', 460, 370, 210, 100, ['Payments assistant', 'Agent + waypoint', 'Approval card'], '#f4efff')
    box('customer', 710, 215, 200, 100, ['customer-agent', 'Agent + waypoint', 'Customer context'])
    box('fraud', 710, 370, 200, 100, ['fraud-agent', 'Agent + waypoint', 'Risk assessment'])
    box('refunds', 710, 525, 200, 100, ['refunds-agent', 'Agent + waypoint', 'Up to £10,000'])
    box('gateway', 955, 215, 220, 410, [], '#f4efff', PURPLE)
    text(1065, 252, 'bank-waypoint', 22, PURPLE, 700)
    text(1065, 280, 'bank-gw service', 16, MUTED)
    text(1065, 320, 'STS-issued identity', 18, INK, 700)
    text(1065, 350, 'JWT · tool policy', 18)
    text(1065, 377, '£10,000 limit', 18)
    for y, label in [(434, 'Anthropic key'), (494, 'Vendor API key'), (554, 'Vault token')]:
        text(1075, y, label, 17, INK, 700)
        shapes.append(f'<circle cx="978" cy="{y-6}" r="5" fill="none" stroke="{PURPLE}" stroke-width="2"/><path d="M983,{y-6}h10m-3,0v5" stroke="{PURPLE}" stroke-width="2"/>')
    text(1065, 601, 'Credentials injected', 16, MUTED)
    box('customers-mcp', 1215, 225, 180, 80, ['customers-mcp', 'Read-only records'])
    box('fraud-mcp', 1215, 380, 180, 80, ['fraud-mcp', 'Vendor request'])
    box('payments-mcp', 1215, 535, 180, 80, ['payments-mcp', 'Bank request'])
    box('anthropic', 1435, 110, 210, 80, ['Anthropic', 'Claude Haiku 4.5'], '#eef9f4')
    box('vendor', 1435, 380, 210, 80, ['Fraud vendor mock', 'Via bank-waypoint', 'Checks X-Api-Key'], '#eef9f4')
    box('core', 1435, 535, 210, 80, ['Core bank mock', 'Via bank-waypoint', 'Checks Vault token'], '#eef9f4')
    box('vault', 1435, 710, 210, 80, ['Vault', 'Revocable bank key'], '#fff4ec')
    edge([(195,265),(240,265)])
    edge([(195,420),(240,420)])
    edge([(330,190),(330,225)])
    edge([(420,265),(460,265)])
    edge([(420,420),(460,420)])
    edge([(670,265),(710,265)])
    edge([(670,420),(690,420),(690,300),(710,300)])
    edge([(670,420),(710,420)])
    edge([(670,420),(690,420),(690,575),(710,575)])
    for y in (265,420,575):
        edge([(910,y),(955,y)])
        edge([(1175,y),(1215,y)])
    edge([(1395,420),(1435,420)])
    edge([(1395,575),(1435,575)])
    edge([(1065,215),(1065,150),(1435,150)])
    text(1260,137,'Model calls from all agents',17,MUTED)
    edge([(195,605),(240,605)],colour='#bf7131')
    edge([(420,605),(440,605),(440,680),(810,680),(810,625)],True,'#bf7131')
    text(608,667,'Stop the refunds agent',17,MUTED)
    edge([(1435,750),(1065,750),(1065,625)],True,'#bf7131')
    text(1220,737,'Provision credential',17,MUTED)
    text(530,765,'A2A calls cross the destination agent’s waypoint.',18,MUTED)
    text(530,795,'Agents exchange tokens at the controller’s STS endpoint.',18,MUTED)
    text(837,837,'No Anthropic key, bank token or vendor key is mounted in an agent or MCP pod.',19,INK,700)
    # Connectors may meet box borders, but no segment may cross a box interior.
    for points in connectors:
        for (x1,y1),(x2,y2) in zip(points,points[1:]):
            assert x1 == x2 or y1 == y2
            for name,(x,y,w,h) in boxes.items():
                crosses = (x1 == x2 and x < x1 < x+w and max(min(y1,y2),y) < min(max(y1,y2),y+h)) or (y1 == y2 and y < y1 < y+h and max(min(x1,x2),x) < min(max(x1,x2),x+w))
                assert not crosses, f'Connector crosses {name}: {(x1,y1),(x2,y2)}'
    svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1670 875" role="img" aria-labelledby="title desc"><title id="title">TrustUs Bank refund architecture</title><desc id="desc">Carol and Bob use five declarative agents. Per-agent waypoints enforce access policies. The shared bank waypoint validates delegated tokens and injects model, vendor and bank credentials.</desc><defs><marker id="arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0 0L8 4L0 8" fill="#8b98b0"/></marker></defs><rect width="1670" height="875" fill="#f8f9fd"/><g font-family="Arial, sans-serif">' + ''.join(shapes) + '</g></svg>'
    (ROOT/'architecture.svg').write_text(svg)
    (ROOT/'architecture.excalidraw').write_text(json.dumps({'type':'excalidraw','version':2,'source':'https://excalidraw.com','elements':elements,'appState':{'viewBackgroundColor':'#f8f9fd','gridSize':None},'files':{}},indent=2))
    print('Wrote architecture.svg and architecture.excalidraw; connector checks passed.')


if __name__ == '__main__':
    build()
