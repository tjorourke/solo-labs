#!/usr/bin/env python3
"""Excuse generator MCP: excuses for late work, each with a believability score.

It knows nothing about you and changes nothing, which is why its AgentRegistry record carries
mcp.governance/auto-approve=true.
"""
import random
import re

from mcp_base import serve

# (style, excuse, believability out of 100)
EXCUSES = [
    ("technical", "DNS was having one of its days, and it is always DNS.", 82),
    ("technical", "The build passed locally, failed in CI, and passed again when I looked at it.", 88),
    ("technical", "A dependency I have never heard of released a breaking change in a patch version.", 90),
    ("technical", "The staging environment was being used for someone else's demo.", 85),
    ("technical", "My laptop decided now was the time for a 47-minute update.", 80),
    ("technical", "The VPN dropped every time I opened the one page I needed.", 78),
    ("technical", "The flaky test was flaky, then flaky about being flaky.", 74),
    ("technical", "A certificate expired at midnight and took the pipeline with it.", 86),
    ("technical", "I fixed the bug, which revealed three older bugs that were holding each other up.", 83),
    ("technical", "The YAML was indented with a tab, and it took me an hour to see it.", 79),
    ("cosmic", "A cosmic ray flipped a bit in the one file I needed.", 12),
    ("cosmic", "Mercury is in retrograde, and so is my merge.", 8),
    ("cosmic", "A solar flare interfered with my Wi-Fi at the exact moment I pressed deploy.", 15),
    ("cosmic", "The moon was full, and so was the disk.", 20),
    ("cosmic", "I was waiting for the planets to align with the release calendar.", 5),
    ("animal", "A pigeon has nested on the antenna and the mesh would not converge.", 18),
    ("animal", "My cat walked across the keyboard and force-pushed to main.", 35),
    ("animal", "A squirrel chewed through the fibre outside the office.", 55),
    ("animal", "The office dog ate the change request. The printed one.", 25),
    ("animal", "A goose chased me away from the data centre door.", 22),
    ("corporate", "It was blocked on a decision from a meeting that was moved to next week.", 92),
    ("corporate", "We aligned on the approach, then re-aligned, then took the alignment offline.", 84),
    ("corporate", "Legal is still reviewing whether the word 'simple' in the README makes a promise.", 60),
    ("corporate", "It is done, it just has not been through the steering committee.", 76),
    ("corporate", "The ticket was reassigned to me, from me, twice.", 70),
    ("corporate", "I was in a meeting about why things are late.", 88),
    ("heroic", "I stopped to fix production for everyone else first.", 72),
    ("heroic", "I found a security hole on the way and closed it before anyone noticed.", 66),
    ("heroic", "I wrote the documentation first, which nobody has ever done.", 30),
    ("heroic", "I was mentoring the intern, who now knows more than me.", 64),
]
STYLES = sorted({s for s, _, _ in EXCUSES})
# Worded so any noun fits: "the release notes" and "the demo" both read right.
LEADS = [
    "Sorry, {thing} will be a little late.",
    "Quick update on {thing}.",
    "About {thing}: small delay.",
    "Heads up on {thing}.",
]
PROMISES = [
    "It will be with you by end of day.",
    "Back on track by tomorrow morning.",
    "Nearly there, promise.",
    "I will send it as soon as the dust settles.",
]
_rng = random.SystemRandom()


def _verdict(score):
    if score >= 85:
        return "Totally believable. Nobody will ask a follow-up question."
    if score >= 65:
        return "Plausible. Say it with confidence."
    if score >= 40:
        return "Risky. Have a second excuse ready."
    if score >= 20:
        return "Your manager will laugh, then ask again."
    return "Only works on a Friday afternoon."


def excuse(args):
    style = (args.get("style") or "").strip().lower()
    thing = (args.get("thing") or "the work").strip()[:80]
    pool = [e for e in EXCUSES if not style or e[0] == style]
    if not pool:
        return {"error": "unknown style", "styles": STYLES}
    s, text, score = _rng.choice(pool)
    return {
        "style": s,
        "message": f"{_rng.choice(LEADS).format(thing=thing)} {text} {_rng.choice(PROMISES)}",
        "excuse": text,
        "believability": score,
        "verdict": _verdict(score),
    }


def excuse_battle(args):
    """Two excuses head to head, one believable and one outrageous."""
    thing = (args.get("thing") or "the work").strip()[:80]
    safe = _rng.choice([e for e in EXCUSES if e[2] >= 70])
    wild = _rng.choice([e for e in EXCUSES if e[2] < 40])
    return {
        "thing": thing,
        "the_safe_one": {"excuse": safe[1], "believability": safe[2], "style": safe[0]},
        "the_wild_one": {"excuse": wild[1], "believability": wild[2], "style": wild[0]},
        "advice": "Use the safe one. Tell the wild one at the pub.",
    }


RULES = [
    (r"\bdns\b", 20, "Blaming DNS is a classic for a reason."),
    (r"\b(ci|pipeline|build|flaky)\b", 15, "Pipelines break. Everyone knows it."),
    (r"\b(meeting|stakeholder|sign-?off|approval)\b", 15, "Blaming process is hard to argue with."),
    (r"\b(dependency|upgrade|update|patch)\b", 12, "Upstream changes are a believable villain."),
    (r"\b(certificate|cert|expired)\b", 12, "Expired certificates have ruined better days than this."),
    (r"\b(cosmic|solar|mercury|retrograde|moon|planet)\b", -40, "Astronomy rarely convinces a manager."),
    (r"\b(dog|cat|pigeon|goose|squirrel)\b", -25, "Animal excuses need photographic evidence."),
    (r"\b(aliens?|ghost|wizard|dragon)\b", -60, "Nobody is buying that."),
    (r"\b(sorry|apolog)", 5, "An apology always helps."),
]


def rate_excuse(args):
    text = (args.get("excuse") or "").strip()
    if not text:
        return {"error": "give me an excuse to rate"}
    score, notes = 50, []
    for pattern, delta, note in RULES:
        if re.search(pattern, text, re.I):
            score += delta
            notes.append(note)
    if len(text) > 220:
        score -= 10
        notes.append("Long excuses sound rehearsed.")
    score = max(1, min(99, score))
    return {"excuse": text, "believability": score, "verdict": _verdict(score),
            "notes": notes or ["Nothing stands out. Neutral, which is sometimes the goal."]}


def excuse_styles(_args):
    return {"styles": {s: sum(1 for e in EXCUSES if e[0] == s) for s in STYLES}}


TOOLS = [
    {"name": "excuse", "description": "A ready-to-send excuse for late work, with a believability score. Optional style and the thing that is late.",
     "inputSchema": {"type": "object", "properties": {
         "thing": {"type": "string", "description": "What is late, for example 'the release notes'."},
         "style": {"type": "string", "description": "technical, corporate, heroic, animal or cosmic."}}}},
    {"name": "excuse_battle", "description": "One believable excuse against one outrageous one.",
     "inputSchema": {"type": "object", "properties": {"thing": {"type": "string"}}}},
    {"name": "rate_excuse", "description": "Score how believable your own excuse is, with notes.",
     "inputSchema": {"type": "object", "properties": {"excuse": {"type": "string"}}, "required": ["excuse"]}},
    {"name": "excuse_styles", "description": "The styles of excuse available.",
     "inputSchema": {"type": "object", "properties": {}}},
]
CALLS = {"excuse": excuse, "excuse_battle": excuse_battle, "rate_excuse": rate_excuse, "excuse_styles": excuse_styles}

if __name__ == "__main__":
    serve("excuse-generator", TOOLS, CALLS)
