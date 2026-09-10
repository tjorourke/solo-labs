#!/usr/bin/env bash
# trace-cost.sh <ask-output-file> — what a turn cost, read out of the A2A trace.
#
# ask.sh prints one numbered entry per tool call the MODEL made, with the response
# after "-> ". Each entry is a round trip that re-sent the whole conversation, and the
# bytes after the arrow are what crossed the context window.
#
# An entry can span many lines: a code-mode program is printed as the program text, so
# the "-> " can be fifty lines below the call. Counting per line undercounts that to
# zero, which flatters code mode by exactly the number the demo is about. So split the
# transcript into entries first, then measure each entry.
set -euo pipefail
python3 - "$1" <<'PY'
import re, sys
from collections import Counter
text = open(sys.argv[1], errors="replace").read()
marks = [(m.start(), m.group(1)) for m in re.finditer(r"^\s+\d+\.\s+([a-z_]+)\(", text, re.M)]
if not marks:
    print("  no tool calls in that trace (ASK_TRACE=0, or the agent answered without tools)")
    raise SystemExit
ends = [m[0] for m in marks[1:]] + [len(text)]
payload = 0
for (start, _), end in zip(marks, ends):
    entry = text[start:end]
    i = entry.find("-> ")
    if i != -1:
        payload += len(entry[i + 3:].rstrip())
by = Counter(name for _, name in marks)
print("  model round trips:          %d" % len(marks))
print("  payload through the model:  %s bytes" % f"{payload:,}")
print("  calls by tool:              %s" % ", ".join("%s x%d" % (k, v) for k, v in by.most_common()))
PY
