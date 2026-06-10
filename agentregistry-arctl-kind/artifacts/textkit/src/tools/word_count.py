"""word_count tool for the textkit MCP server.

Counts words, characters, and sentences in a block of text. The summarizer
agent calls this to ground its length budget on the real size of the input
instead of guessing.

The file name (`word_count`) must match the function name (`word_count`) —
the dynamic loader in core/server.py discovers tools by that convention.
"""

import re

from core.server import mcp


@mcp.tool(
    description=(
        "Count the words, characters, and sentences in a block of text. "
        "Call this before summarizing so the summary length is proportional "
        "to the input size."
    )
)
def word_count(text: str) -> dict:
    """Return word, character, and sentence counts for the given text.

    Args:
        text: The text to measure.

    Returns:
        A dict with `words`, `characters`, and `sentences` integer counts.
    """
    words = re.findall(r"\b\w+\b", text)
    sentences = re.findall(r"[.!?]+(?:\s|$)", text)
    return {
        "words": len(words),
        "characters": len(text),
        "sentences": max(len(sentences), 1 if text.strip() else 0),
    }
