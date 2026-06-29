#!/usr/bin/env bash
# Continuous availability monitor for the app hostname. Run it in the
# background during the migration to prove zero downtime. Logs the HTTP code
# and which gateway is currently serving (resolved via the DNS target), so you
# can see the cutover happen with no failed requests.
#
# Prereqs: source ../env.sh (APP_HOST, BASE_DOMAIN). OPENSHIFT_LB / AGW_LB are
# the two gateway LB hostnames (printed by scripts 01 and 03).
#   OPENSHIFT_LB=... AGW_LB=... ./02-monitor.sh &
set -uo pipefail
: "${APP_HOST:?}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HERE/evidence/availability.log"; : > "$LOG"
OPENSHIFT_LB="${OPENSHIFT_LB:-}"; AGW_LB="${AGW_LB:-}"
ok=0; fail=0
for i in $(seq 1 1200); do
  ts=$(date +%H:%M:%S)
  code=$(curl -s -m 4 -o /dev/null -w '%{http_code}' "http://${APP_HOST}/" 2>/dev/null)
  tgt=$(dig +short "${APP_HOST}" 2>/dev/null | grep -E '\.elb\.' | head -1)
  case "$tgt" in
    "${OPENSHIFT_LB}"*) gw="OPENSHIFT-gw" ;;
    "${AGW_LB}"*)       gw="AGENTGATEWAY" ;;
    *)                  gw="?" ;;
  esac
  [ "$code" = "200" ] && ok=$((ok+1)) || fail=$((fail+1))
  echo "$ts code=$code via=$gw ok=$ok fail=$fail" >> "$LOG"
  sleep 1
done
