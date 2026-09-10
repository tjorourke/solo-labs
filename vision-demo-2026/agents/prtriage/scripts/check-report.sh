#!/usr/bin/env bash
# check-report.sh <ask-output-file> — is the report actually right?
#
# WHY THIS EXISTS
# A demo must not depend on the model making a mistake. The comparison between tool
# modes is about tool overhead and where the data is handled, and BOTH reports should
# be checked against the fixture rather than one of them being assumed wrong.
#
# It reads the truth from GitHub (draft flag, do-not-merge/hold label, a comment
# starting with LGTM), parses the report out of an ask.sh transcript, and prints a
# per-verdict comparison. Exit 0 when the report matches, 1 when it does not.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -ge 1 ] || { echo "usage: check-report.sh <ask-output-file>"; exit 2; }
export REPORT="$1"
export REPO="${DEMO_REPO:-tjorourke/kagent}"
export PAT="${GITHUB_PAT:-${GITHUB_PORTLAB_TOKEN:-}}"
[ -n "$PAT" ] || { echo "✗ set GITHUB_PAT so the fixture truth can be read"; exit 2; }
python3 "$HERE/check_report.py"
