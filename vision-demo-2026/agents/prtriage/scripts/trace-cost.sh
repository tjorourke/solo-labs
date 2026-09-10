#!/usr/bin/env bash
# trace-cost.sh <ask-output-file> — what a turn cost, read out of the A2A trace.
#
# ask.sh prints one numbered line per tool call the MODEL made, with the response
# after "-> ". Each of those lines is a round trip that re-sent the whole
# conversation, and the bytes after the arrow crossed the context window.
set -euo pipefail
python3 - "$1" <<'PY'
import re,sys
from collections import Counter
lines=[l for l in open(sys.argv[1]) if re.match(r'^\s+\d+\.\s+\S+\(',l)]
if not lines:
    print("  no tool calls in that trace (ASK_TRACE=0, or the agent answered without tools)")
    raise SystemExit
payload=sum(len(l.split('-> ',1)[1]) for l in lines if '-> ' in l)
by=Counter(re.match(r'^\s+\d+\.\s+([a-z_]+)\(',l).group(1) for l in lines)
print("  model round trips:          %d" % len(lines))
print("  payload through the model:  %s bytes" % f"{payload:,}")
print("  calls by tool:              %s" % ", ".join("%s x%d"%(k,v) for k,v in by.most_common()))
PY
