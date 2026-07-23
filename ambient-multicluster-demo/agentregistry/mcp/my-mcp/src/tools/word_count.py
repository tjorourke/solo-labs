"""word_count — count the words in a piece of text."""

from core.server import mcp


@mcp.tool(description="Count the number of words in a piece of text.")
def word_count(text: str) -> int:
    """Count the words in the given text.

    Args:
        text: The text to count words in

    Returns:
        The number of whitespace-separated words
    """
    return len(text.split())
