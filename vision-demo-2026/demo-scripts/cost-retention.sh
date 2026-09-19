#!/usr/bin/env bash
# cost-retention.sh — put a retention window on the Cost Management rollups on a
# demo cluster that is left up for weeks.
#
#   ./demo-scripts/cost-retention.sh            apply the default 3 day window
#   AD_RETENTION_DAYS=7 ./demo-scripts/cost-retention.sh
#   ./demo-scripts/cost-retention.sh status     show table sizes and current TTLs
#
# Re-runnable. A Helm upgrade of the management chart may recreate the tables,
# so run it again after one.
set -Eeuo pipefail
CTX="${CTX:-kind-mesh1}"
NS="${COST_NS:-solo-cost}"
POD="${COST_POD:-management-clickhouse-shard0-0}"
DAYS="${AD_RETENTION_DAYS:-3}"
DB=platformdb

ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
ch()  { kubectl --context "$CTX" -n "$NS" exec "$POD" -- clickhouse-client -q "$1"; }

kubectl --context "$CTX" -n "$NS" get pod "$POD" >/dev/null 2>&1 \
  || die "$POD not found in $NS (is Cost Management installed?)"

if [ "${1:-apply}" = "status" ]; then
  printf '\n%-34s %10s %12s %s\n' TABLE ROWS SIZE TTL
  ch "
    SELECT t.name,
           sum(p.rows),
           replaceAll(formatReadableSize(sum(p.bytes_on_disk)),' ',''),
           if(t.create_table_query LIKE '%TTL%','yes','NO')
    FROM system.tables t
    LEFT JOIN system.parts p ON p.table=t.name AND p.database=t.database AND p.active
    WHERE t.database='$DB' AND t.engine NOT LIKE '%View%'
    GROUP BY t.name, t.create_table_query
    HAVING sum(p.rows) > 0
    ORDER BY sum(p.rows) DESC FORMAT TSV" \
  | awk '{printf "%-34s %10s %12s %s\n", $1, $2, $3, $4}'
  echo
  exit 0
fi

echo "Applying a ${DAYS} day retention window to the Cost Management rollups"

# Every rollup keyed on a five minute bucket. ttl_only_drop_parts is already set
# on these tables and they partition by day, so expiry drops whole parts rather
# than rewriting rows, which is the cheap path.
BUCKET_TABLES="$(ch "
  SELECT name FROM system.tables
  WHERE database='$DB' AND engine NOT LIKE '%View%'
    AND create_table_query NOT LIKE '%TTL%'
    AND name IN (SELECT table FROM system.columns WHERE database='$DB' AND name='bucket')
  FORMAT TSV")"

for t in $BUCKET_TABLES; do
  ch "ALTER TABLE $DB.$t MODIFY TTL bucket + INTERVAL $DAYS DAY" >/dev/null \
    && ok "$t  (bucket + ${DAYS}d)" || die "could not set TTL on $t"
done

# The span tables key on Timestamp instead. agw_spans_typed is the biggest by
# bytes; the chat span tables only grow when the demo is actually used, which is
# exactly when they are worth bounding.
for t in agw_spans_typed agw_chat_spans kagent_chat_spans; do
  ch "EXISTS TABLE $DB.$t" | grep -q 1 || continue
  if ch "SELECT create_table_query FROM system.tables WHERE database='$DB' AND name='$t'" | grep -q TTL; then
    ok "$t already has a TTL"
    continue
  fi
  ch "ALTER TABLE $DB.$t MODIFY TTL toDateTime(Timestamp) + INTERVAL $DAYS DAY" >/dev/null \
    && ok "$t  (Timestamp + ${DAYS}d)" || die "could not set TTL on $t"
done

echo
echo "Done. Expired parts are dropped in the background; run:"
echo "  ./demo-scripts/cost-retention.sh status"
