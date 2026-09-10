#!/usr/bin/env bash
# seed-demo-repo.sh — build the frozen pull-request fixtures the demo reads.
#
# WHY
# Reading live pull requests from a busy upstream repo is a bad bet on a projector:
# the answer changes hour to hour, the numbers stop matching your slides, and the
# model sometimes over-fetches and trips code mode's 20-call cap. This seeds a repo
# you own with exactly 8 open pull requests in known states, so the report is
# identical every run and "all open pull requests" is always 8 (17 upstream calls,
# comfortably under the cap).
#
# HOW THE GATE IS BUILT, AND WHY IT IS NOT ABOUT APPROVALS
# GitHub will not let you approve your own pull request, and a personal access token
# cannot create check runs. So the gate uses three things we do control, all of them
# ordinary in real repos:
#   - draft status
#   - a failing COMMIT STATUS (the statuses API, which a PAT can write) read back via
#     pull_request_read method=get_status. No GitHub Actions needed, which matters:
#     this repo is a fork of kagent and enabling Actions would fire kagent's whole
#     workflow set for one red tick.
#   - a sign-off comment beginning with LGTM
#
# The PRs target the FORK's own default branch, so nothing reaches kagent-dev.
#
# REQUIREMENTS  GITHUB_PAT (or GITHUB_PORTLAB_TOKEN) with, on the target repo:
#               Contents: write, Pull requests: write, Commit statuses: write,
#               Issues: write (for the comment and label)
# USAGE         REPO=tjorourke/kagent ./scripts/seed-demo-repo.sh
#               RESEED=1 REPO=... ./scripts/seed-demo-repo.sh   # close and start over
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO="${REPO:-tjorourke/kagent}"
export PAT="${GITHUB_PAT:-${GITHUB_PORTLAB_TOKEN:-}}"
[ -n "$PAT" ] || { echo "✗ set GITHUB_PAT"; exit 1; }
export FIXTURES="$HERE/../fixtures/prs.json"
export RESEED="${RESEED:-}"
python3 "$HERE/seed_demo_repo.py"
