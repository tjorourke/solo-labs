"""Load skills that were baked into the agent image at build time.

The Agent kind in AgentRegistry has no `skills` reference today, so a skill
reaches the agent one of two ways: pulled at startup, or baked into the image.
This lab bakes it. The `summary-style` skill's SKILL.md is copied into
`summarizer/skills/` before `arctl build`, and this loader reads every `.md`
there, strips the YAML frontmatter, and returns the bodies so they can be
folded into the agent's instruction.
"""

from pathlib import Path
from typing import List

_SKILLS_DIR = Path(__file__).parent / "skills"


def _strip_frontmatter(text: str) -> str:
    """Drop a leading `--- ... ---` YAML frontmatter block if present."""
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            return text[end + 4:].lstrip("\n")
    return text


def load_baked_skills() -> str:
    """Return the concatenated body of every baked skill, or an empty string."""
    if not _SKILLS_DIR.is_dir():
        return ""
    parts: List[str] = []
    for path in sorted(_SKILLS_DIR.glob("*.md")):
        body = _strip_frontmatter(path.read_text(encoding="utf-8")).strip()
        if body:
            parts.append(body)
    return "\n\n".join(parts)
