# Part 8 diagrams

The four SVGs embedded in `demo-8-github-agent.ipynb`, kept here as files so they can be
edited and re-rendered without digging them out of notebook JSON.

| file | where it appears |
|---|---|
| `arch.svg` | the title, the three products in one line |
| `cost.svg` | step 1, what one MCP server costs |
| `modes.svg` | step 5, Standard against CodeSearch |
| `identity.svg` | step 6, two agents and one integration |

House style follows the Part 4 diagrams: `viewBox="0 0 740 …"`, a `#f8fafc` ground, dark
slate ink, and the green / indigo / amber accents. White background and dark ink, never
the dark code palette.

**Render-check before committing a change.** Hand-estimated coordinates drift, so look
at the result rather than trusting the numbers:

```bash
python3 -c "import pathlib;s=pathlib.Path('arch.svg').read_text();pathlib.Path('/tmp/a.html').write_text('<html><body style=\"margin:0;background:#fff\">%s</body></html>'%s)"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu \
  --screenshot=/tmp/a.png --window-size=1000,440 --default-background-color=FFFFFFFF /tmp/a.html
open /tmp/a.png
```

Check that no arrow crosses a box, every label sits inside its box and inside the
viewBox, and nothing is clipped. The identity diagram lost a GitHub box during review
for exactly this sort of reason: the single arrow into it implied only the release agent
ever reached GitHub, when both agents read from it.

To re-embed after editing, re-run the notebook builder, or paste the file contents into
the matching figure cell.
