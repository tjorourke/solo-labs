---
name: summary-style
description: The house format every summary must follow. Use this whenever you are asked to summarize, condense, or shorten a block of text. It sets the length budget, the bullet rules, and the sources line.
---

# Summary house style

Follow this format every time you summarize text. It keeps summaries consistent
and scannable across the team.

## Workflow

1. Call the `word_count` tool on the input first. Use the word count to size the
   summary: aim for roughly 10% of the input length, and never more than 150 words.
2. Call the `extract_links` tool on the input. If it returns any links, list them
   under a `Sources:` line at the end of the summary.
3. Write the summary in the format below.

## Format

- Open with a single bold one-line takeaway (the headline), no more than 20 words.
- Follow with 3 to 5 bullet points. Each bullet is one sentence, starts with a
  capital letter, and has no trailing period.
- Use bullet points for any list of 3 or more items.
- Preserve factual accuracy. Do not introduce facts that are not in the source.
- If the input names action items or deadlines, call them out in their own bullet
  prefixed with `Action:`.
- End with a `Sources:` line listing the URLs from `extract_links`, comma
  separated. Omit the line entirely if there were no links.

## Example shape

**Headline takeaway in one line**

- First key point
- Second key point
- Action: the thing someone has to do, and by when

Sources: https://example.com/a, https://example.com/b
