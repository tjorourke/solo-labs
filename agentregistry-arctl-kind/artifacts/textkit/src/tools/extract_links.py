"""extract_links tool for the textkit MCP server.

Pulls every URL out of a block of text and returns them de-duplicated, in the
order they first appear. The summarizer agent uses this to list source links
under its summary without re-reading the whole document.

The file name (`extract_links`) must match the function name — the dynamic
loader in core/server.py discovers tools by that convention.
"""

import re

from core.server import mcp

_URL_RE = re.compile(r"https?://[^\s<>\")']+")


@mcp.tool(
    description=(
        "Extract every http/https URL from a block of text, de-duplicated and "
        "in first-seen order. Use this to list the source links for a summary."
    )
)
def extract_links(text: str) -> dict:
    """Return the unique URLs found in the given text.

    Args:
        text: The text to scan for links.

    Returns:
        A dict with `count` and `links` (a list of URL strings).
    """
    seen: list[str] = []
    for match in _URL_RE.findall(text):
        url = match.rstrip(".,);]")
        if url not in seen:
            seen.append(url)
    return {"count": len(seen), "links": seen}
