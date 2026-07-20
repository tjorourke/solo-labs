#!/usr/bin/env bash
# Backfill ClickHouse with N days of synthetic agentgateway LLM spend so the
# Cost Management dashboards (Spend Over Time, Spend by Model, Dimensions,
# Budgets) render full without waiting for live traffic to accrue.
#
# It inserts fully-formed rows into platformdb.agw_spans_typed; the built-in
# materialized views (agw_cost_model_5m_mv, agw_cost_dimensions_5m_mv) fire on
# insert and populate the 5-minute rollups the UI reads. Idempotent-ish: re-runs
# add more spend, so TRUNCATE first if you want a clean slate.
set -euo pipefail

CTX="${CTX:-kind-agentgateway-cost}"
CH_POD="${CH_POD:-management-clickhouse-shard0-0}"
NS="${NS:-kagent}"
ROWS="${ROWS:-300000}"     # ~ request count over the window
DAYS="${DAYS:-30}"

ch() { kubectl --context "$CTX" exec -n "$NS" "$CH_POD" -- clickhouse-client "$@"; }

if [ "${TRUNCATE:-false}" = "true" ]; then
  echo "Truncating agw_spans_typed + cost rollups for a clean slate ..."
  for t in agw_spans_typed agw_cost_model_5m agw_cost_dimensions_5m; do
    ch --query "TRUNCATE TABLE platformdb.$t"
  done
fi

echo "Seeding ${ROWS} synthetic spans across ${DAYS}d into platformdb.agw_spans_typed ..."

ch --query "
INSERT INTO platformdb.agw_spans_typed
WITH
  ['gpt-4o','claude-sonnet-4-5','claude-haiku-3-5','gpt-4o-mini','gemini-2.0-flash'] AS models,
  ['openai','anthropic','anthropic','openai','google']                              AS provs,
  [2.50, 3.00, 0.80, 0.15, 0.10]  AS inRate,   -- USD / 1M input tokens
  [10.0, 15.0, 4.00, 0.60, 0.40]  AS outRate,  -- USD / 1M output tokens
  -- weighted model pick: gpt-4o & sonnet dominate spend (like the demo)
  [1,1,1,1,1,2,2,2,2,2,3,3,3,4,4,4,5,5,5,5]   AS mw,
  ['research','ml-platform','engineering','product'] AS groups,
  ['cc-research','cc-mlplat','cc-eng','cc-product']  AS ccs,
  ['prod','staging','dev']                           AS envs,
  ['atlas','orion','nova','helix']                   AS projects,
  ['support-bot','code-assist','data-pipeline','chatops','search-api','doc-gen','analytics','recommender'] AS apps,
  ['alice','bob','carol','dave','erin','frank','grace','heidi'] AS users,
  number AS n,
  mw[(rand(n*7)%20)+1]                     AS mi,          -- 1-based model index
  (rand(n*3)%4)+1                          AS gi,
  now() - toIntervalSecond(toUInt64(rand(n)%(${DAYS}*86400))) AS ts,
  2000 + (rand(n*11)%38000)                AS intok,
  800  + (rand(n*13)%16000)                AS outtok,
  toDecimal128((toFloat64(intok)*inRate[mi] + toFloat64(outtok)*outRate[mi]) / 1000000.0, 18) AS cost
SELECT
  ts                                         AS Timestamp,
  lower(hex(reinterpretAsFixedString(cityHash64(n)))) AS TraceId,
  lower(hex(reinterpretAsFixedString(cityHash64(n+1)))) AS SpanId,
  ''                                         AS ParentSpanId,
  'enterprise-agentgateway'                  AS ServiceName,
  'chat'                                     AS SpanName,
  200000000 + (rand(n*5)%3000000000)         AS Duration,
  models[mi]                                 AS RequestModel,
  toUInt64(intok)                            AS InputTokens,
  toUInt64(outtok)                           AS OutputTokens,
  'llm'                                       AS Route,
  '/v1/chat/completions'                     AS HttpPath,
  200                                         AS HttpStatus,
  ''  AS MCPTarget, '' AS MCPResourceName, '' AS MCPResourceType, '' AS ToolName, '' AS ErrorMsg,
  1                                           AS IsRoot,
  1                                           AS HasAttrs,
  provs[mi]                                   AS Provider,
  models[mi]                                  AS ResponseModel,
  cost                                        AS CostUsd,
  toDecimal128(0,18)                          AS CacheReadCostUsd,
  toDecimal128(0,18)                          AS CacheWriteCostUsd,
  map(
    'group',       groups[gi],
    'costCenter',  ccs[gi],
    'environment', envs[(rand(n*17)%3)+1],
    'project',     projects[(rand(n*19)%4)+1],
    'application', apps[(rand(n*31)%8)+1],
    'user',        users[(rand(n*23)%8)+1],
    'virtualKey',  concat('vk-', groups[gi], '-', toString((rand(n*29)%5)+1))
  )                                           AS CustomDimensions,
  'agentgateway-cost'                         AS Cluster,
  'gloo-system'                               AS Namespace
FROM numbers(${ROWS})
"

echo "Done. Rollup summary:"
ch --query "
SELECT 'requests' k, formatReadableQuantity(count()) v FROM platformdb.agw_spans_typed
UNION ALL SELECT 'tokens', formatReadableQuantity(sum(InputTokens+OutputTokens)) FROM platformdb.agw_spans_typed
UNION ALL SELECT 'spend_usd', concat('\$', toString(round(sum(CostUsd),0))) FROM platformdb.agw_spans_typed
"
