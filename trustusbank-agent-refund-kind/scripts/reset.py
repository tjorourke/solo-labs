"""Reset only the standalone refund lab's data, and read the result back.

The native session delete endpoint soft-deletes conversations. A complete demo
reset also purges those rows and their events, tasks and approval state. No
product code, agents, IdP configuration or platform resources are changed.
"""
import json
import re
import subprocess
import time
from pathlib import Path

from client import CTX
from gateway_client import receipts

LAB = Path(__file__).resolve().parents[1]
AGENTS = ('customer-service-assistant', 'payments-assistant', 'payments-manager',
          'customer-agent', 'fraud-agent', 'refunds-agent')
AGENT_IDS = tuple('bank__NS__' + name.replace('-', '_') for name in AGENTS)
TRACE_TABLES = ('otel_traces_json', 'agw_spans_typed', 'agw_chat_spans',
                'kagent_chat_spans', 'trace_time_index', 'otel_logs_json')
LOCAL_EVIDENCE = tuple(Path('/tmp') / name for name in (
    'trustusbank-evidence.json', 'trustusbank-traces.json', 'trustusbank-failed-checks.json'))
RESOURCE_SCOPE = ("JSONExtractString(toJSONString(ResourceAttributes), 'k8s', 'namespace', 'name') = 'bank' "
                  "AND JSONExtractString(toJSONString(ResourceAttributes), 'cluster_name') = 'trustusbank-lab'")


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def ch_literal(value):
    return "'" + value.replace('\\', '\\\\').replace("'", "\\'") + "'"


def kube(*args, data=None):
    command = ['kubectl', '--context', CTX]
    arguments = list(args)
    if data is not None:
        arguments.insert(arguments.index('exec') + 1, '-i')
    result = subprocess.run(command + arguments, input=data, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=240)
    if result.returncode:
        raise RuntimeError(result.stderr.strip()[-1500:] or 'Kubernetes command failed')
    return result.stdout


def postgres(query):
    return kube('-n', 'kagent', 'exec', 'deployment/kagent-postgresql', '--', 'sh', '-c',
                'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -qAt '
                '-U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"', data=query)


def clickhouse(query):
    return kube('-n', 'agentgateway-system', 'exec', 'management-clickhouse-shard0-0',
                '--', 'clickhouse-client', '--multiquery', data=query)


def session_scope(alias='s'):
    return alias + '.agent_id IN (' + ','.join(map(literal, AGENT_IDS)) + ')'


def postgres_reset_sql():
    """One transaction; every delete joins the explicit bank session scope."""
    return f"""BEGIN;
CREATE TEMP TABLE refund_reset_sessions ON COMMIT DROP AS
  SELECT id,user_id FROM session s WHERE {session_scope()};
CREATE TEMP TABLE refund_reset_tasks ON COMMIT DROP AS
  SELECT t.id FROM task t JOIN refund_reset_sessions s
    ON t.session_id=s.id AND t.user_id=s.user_id;
DELETE FROM push_notification p USING refund_reset_tasks t WHERE p.task_id=t.id;
DELETE FROM session_share p USING refund_reset_sessions s
  WHERE p.session_id=s.id AND p.user_id=s.user_id;
DELETE FROM lg_checkpoint_write p USING refund_reset_sessions s
  WHERE p.thread_id=s.id AND p.user_id=s.user_id;
DELETE FROM lg_checkpoint p USING refund_reset_sessions s
  WHERE p.thread_id=s.id AND p.user_id=s.user_id;
DELETE FROM crewai_agent_memory p USING refund_reset_sessions s
  WHERE p.thread_id=s.id AND p.user_id=s.user_id;
DELETE FROM crewai_flow_state p USING refund_reset_sessions s
  WHERE p.thread_id=s.id AND p.user_id=s.user_id;
DELETE FROM event p USING refund_reset_sessions s
  WHERE p.session_id=s.id AND p.user_id=s.user_id;
DELETE FROM task p USING refund_reset_sessions s
  WHERE p.session_id=s.id AND p.user_id=s.user_id;
DELETE FROM session p USING refund_reset_sessions s
  WHERE p.id=s.id AND p.user_id=s.user_id AND {session_scope('p')};
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM event p JOIN refund_reset_sessions s ON p.session_id=s.id AND p.user_id=s.user_id)
     OR EXISTS (SELECT 1 FROM task p JOIN refund_reset_sessions s ON p.session_id=s.id AND p.user_id=s.user_id)
     OR EXISTS (SELECT 1 FROM session s WHERE {session_scope()}) THEN
    RAISE EXCEPTION 'Still present: bank conversations, events or approval tasks';
  END IF;
END $$;
SELECT count(*) FROM refund_reset_sessions;
COMMIT;
"""


def saved_trace_ids():
    # Extract only trace IDs, never prompt bodies or saved bearer headers.
    raw = postgres(f"""SELECT DISTINCT split_part(
      e.data::jsonb #>> '{{actions,state_delta,headers,traceparent}}', '-', 2)
      FROM event e JOIN session s ON e.session_id=s.id AND e.user_id=s.user_id
      WHERE {session_scope()} AND e.data::jsonb #>> '{{actions,state_delta,headers,traceparent}}' IS NOT NULL;""")
    return {line for line in raw.splitlines() if re.fullmatch('[0-9a-f]{32}', line)}


def trace_ids_before(cutoff):
    raw = clickhouse(f"""SELECT DISTINCT TraceId FROM (
      SELECT TraceId FROM platformdb.otel_traces_json
        WHERE {RESOURCE_SCOPE} AND Timestamp <= fromUnixTimestamp64Nano({cutoff})
      UNION ALL SELECT TraceId FROM platformdb.agw_spans_typed
        WHERE Namespace='bank' AND Cluster='trustusbank-lab' AND Timestamp <= fromUnixTimestamp64Nano({cutoff})
      UNION ALL SELECT TraceId FROM platformdb.kagent_chat_spans
        WHERE Namespace='bank' AND Cluster='trustusbank-lab' AND Timestamp <= fromUnixTimestamp64Nano({cutoff})
      UNION ALL SELECT TraceId FROM platformdb.otel_logs_json
        WHERE {RESOURCE_SCOPE} AND Timestamp <= fromUnixTimestamp64Nano({cutoff})
    ) FORMAT TSV;""")
    return {line for line in raw.splitlines() if re.fullmatch('[0-9a-f]{32}', line)}


def trace_delete_queries(ids):
    ordered = sorted(ids)
    if any(not re.fullmatch('[0-9a-f]{32}', value) for value in ordered):
        raise ValueError('Invalid trace ID')
    for offset in range(0, len(ordered), 500):
        values = ','.join(map(ch_literal, ordered[offset:offset + 500]))
        for table in TRACE_TABLES:
            yield f'ALTER TABLE platformdb.{table} DELETE WHERE TraceId IN ({values}) SETTINGS mutations_sync=2;'


def purge_traces(ids):
    queries = list(trace_delete_queries(ids))
    if queries:
        clickhouse('\n'.join(queries))
    ordered = sorted(ids)
    for offset in range(0, len(ordered), 500):
        values = ','.join(map(ch_literal, ordered[offset:offset + 500]))
        for table in TRACE_TABLES:
            remaining = int(clickhouse(f'SELECT count() FROM platformdb.{table} WHERE TraceId IN ({values});').strip())
            if remaining:
                raise RuntimeError('Still present: bank trace rows in ' + table)


def purge_summaries(services):
    # These tables are trace-derived, not the live Kubernetes-object catalogue.
    statements = [
        "ALTER TABLE platformdb.agw_node_model_5m DELETE WHERE namespace='bank' AND cluster='trustusbank-lab' SETTINGS mutations_sync=2;",
        "ALTER TABLE platformdb.agw_node_tool_5m DELETE WHERE namespace='bank' AND cluster='trustusbank-lab' SETTINGS mutations_sync=2;",
    ]
    if services:
        values = ','.join(map(ch_literal, services))
        for table in ('agw_trace_model_5m', 'agw_trace_request_counts_5m',
                      'agw_trace_route_5m', 'agw_trace_tool_5m',
                      'agw_cost_model_5m', 'agw_cost_dimensions_5m'):
            statements.append(f'ALTER TABLE platformdb.{table} DELETE WHERE service_name IN ({values}) SETTINGS mutations_sync=2;')
    clickhouse('\n'.join(statements))


def reset():
    if CTX != 'kind-trustusbank-lab':
        raise RuntimeError('Refund reset is scoped to kind-trustusbank-lab')
    raw = kube('get', 'namespace', 'bank', '--ignore-not-found', '-o', 'json')
    if not raw.strip():
        print('SKIP: standalone refund lab is not installed.', flush=True)
        return
    namespace = json.loads(raw)
    if namespace['metadata'].get('labels', {}).get('bank.trustus/owner') != 'refund-lab':
        raise RuntimeError('Bank namespace is not owned by the refund lab')

    print('Restoring refunds and restarting only bank agents and the mock bank…', flush=True)
    kube('-n', 'bank', 'delete', 'accesspolicy', 'refunds-agent-killswitch', '--ignore-not-found')
    kube('-n', 'bank', 'wait', '--for=delete',
         'enterpriseagentgatewaypolicy/accesspolicy-refunds-agent-killswitch-waypoint', '--timeout=60s')
    deployments = [*(f'deployment/{name}' for name in AGENTS), 'deployment/core-bank']
    kube('-n', 'bank', 'rollout', 'restart', *deployments)
    for deployment in deployments:
        kube('-n', 'bank', 'rollout', 'status', deployment, '--timeout=180s')
    if receipts():
        raise RuntimeError('Still present: synthetic bank receipts')

    ids = saved_trace_ids()
    removed = int(postgres(postgres_reset_sql()).strip())
    print(f'Purged {removed} bank conversations, including soft-deleted history and approval tasks.', flush=True)
    for path in LOCAL_EVIDENCE:
        path.unlink(missing_ok=True)
    # Restarted agents flush in-flight spans; allow the shared OTLP batch to drain.
    time.sleep(10)
    cutoff = time.time_ns()
    services = [line for line in clickhouse(f"""SELECT ServiceName FROM platformdb.otel_traces_json
        GROUP BY ServiceName HAVING countIf({RESOURCE_SCOPE}) > 0
        AND countIf(NOT ({RESOURCE_SCOPE})) = 0 FORMAT TSV;""").splitlines() if line]
    for attempt in range(3):
        ids.update(trace_ids_before(cutoff))
        purge_traces(ids)
        time.sleep(5)
        if not trace_ids_before(cutoff):
            break
    else:
        raise RuntimeError('Still present: historical bank traces after collector drain')
    purge_summaries(services)
    if int(postgres(f'SELECT count(*) FROM session s WHERE {session_scope()};').strip()):
        raise RuntimeError('Still present: a new bank conversation; close active chats and retry')
    if any(path.exists() for path in LOCAL_EVIDENCE):
        raise RuntimeError('Still present: saved bank evidence files')
    print(f'Purged {len(ids)} historical bank trace IDs, derived prompt/trace views and linked logs.', flush=True)
    print('Reset verified: history, pending approvals, receipts, kill switch and saved evidence are clear.', flush=True)
    print('Start new agent chats. The lab platform, IdP groups and policies were retained.', flush=True)
    print('New background discovery can create fresh technical traces after this reset.', flush=True)


if __name__ == '__main__':
    reset()
