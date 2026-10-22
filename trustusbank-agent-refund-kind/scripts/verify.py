"""Run the eight-step story and negative controls against the live lab."""
import base64
import json
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from client import Client, CTX
from gateway_client import MCP, claims, exchange, kube, receipts
from evidence import approved_record, delegated_tool_result, session_evidence

HERE = Path(__file__).parent
checks, sessions = {}, {}


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    checks[name] = 'passed'
    print('PASS', name, flush=True)


def ask(client, agent, prompt, name, context_id=None):
    code, body = client.ask(agent, prompt, context_id)
    check(name + ': transport', code == 200 and 'error' not in body)
    task = body['result']
    check(name + ': completed', task['status']['state'] == 'completed')
    sessions[name] = session_evidence(client, task)
    return task


def switch(state):
    subprocess.run(['bash', str(HERE / 'killswitch.sh'), state], check=True)


def telemetry(clients):
    ids = {trace for session in sessions.values() for trace in session['trace_ids']}
    check('Trace IDs captured', bool(ids) and all(re.fullmatch('[0-9a-f]{32}', t) for t in ids))
    where = 'TraceId IN (' + ','.join("'" + t + "'" for t in ids) + ')'
    query = "SELECT count() AS spans, countIf(StatusCode = 'Error') AS errors, countIf(SpanName LIKE '%openai%') AS models, countIf(arrayExists(p -> startsWith(p, 'gen_ai.usage'), JSONAllPaths(SpanAttributes))) AS usage FROM platformdb.otel_traces_json WHERE " + where + ' FORMAT JSONEachRow'
    prefix = ('-n', 'agentgateway-system', 'exec', 'management-clickhouse-shard0-0', '--', 'clickhouse-client', '--query')
    for _ in range(30):
        result = {k: int(v) for k, v in json.loads(kube(*prefix, query)).items()}
        if result['spans'] and result['errors'] and result['models'] and result['usage']:
            break
        time.sleep(2)
    check('Collector contains model, usage and error spans', all(result[k] > 0 for k in ['spans', 'errors', 'models', 'usage']))
    raw = kube(*prefix, 'SELECT toJSONString(SpanAttributes) FROM platformdb.otel_traces_json WHERE ' + where + ' FORMAT TSVRaw')
    secrets = json.loads(kube('-n', 'bank', 'get', 'secrets', 'anthropic-key', 'core-bank-key', 'fraud-vendor-key', '-o', 'json'))['items']
    values = [base64.b64decode(v).decode() for s in secrets for v in s['data'].values()]
    values.extend(token for client in clients for token in client.issued_tokens)
    check('No credential values or user bearers in span attributes', all(value not in raw for value in values))
    return result


def main():
    switch('off')
    kube('-n', 'bank', 'rollout', 'restart', 'deployment/core-bank')
    kube('-n', 'bank', 'rollout', 'status', 'deployment/core-bank', '--timeout=120s')
    bob, carol = Client('bob'), Client('carol')
    ask(carol, 'customer-service-assistant',
        'A customer says payment PAY-7781 failed this morning and the money has left their account. What happened?', 'carol')
    check('Carol delegated to customer-agent', any('customer_agent' in c['name'] for c in sessions['carol']['calls']))
    customer = delegated_tool_result(carol, sessions['carol'], 'customer-agent', 'get_customer')
    check('Carol received the actual customer record',
          customer['payment_id'] == 'PAY-7781' and customer['customer'] == 'Morgan Taylor'
          and customer['amount_gbp'] == 1250 and customer['status'] == 'FAILED'
          and customer['debit_status'] == 'DEBITED')
    sessions['carol']['customer_record'] = customer
    code, body = carol.ask('payments-assistant', 'Please refund GBP 1,250 to the customer for PAY-7781.')
    check('Carol refused payments assistant', code == 403 or '403' in str(body.get('error', {})))
    refusal_log = kube('-n', 'bank', 'logs', 'deployment/agent-payments-assistant-waypoint', '--since=2m')
    carol_sub = claims(carol.token)['sub']
    refusal_trace = next((re.search(r'trace.id=([0-9a-f]{32})', line).group(1)
                          for line in reversed(refusal_log.splitlines())
                          if 'http.status=403' in line and 'jwt.sub=' + carol_sub in line
                          and re.search(r'trace.id=([0-9a-f]{32})', line)), None)
    check('Carol refusal has a persisted gateway trace', refusal_trace is not None)
    sessions['refused'] = {'user': 'carol', 'state': 'rejected',
                           'trace_id': refusal_trace, 'trace_ids': [refusal_trace]}
    for user in (bob, carol):
        code, body = user.ask('refunds-agent', 'Check payment PAY-7781.')
        check(user.user + ': direct specialist access refused', code == 403 or '403' in str(body.get('error', {})))
    ask(bob, 'payments-assistant', 'Look into PAY-7781 for me. The customer was charged but the merchant says nothing arrived.', 'investigate')
    names = {c['name'] for c in sessions['investigate']['calls']}
    check('Three A2A specialists', all(any(n in c for c in names) for n in ['customer_agent', 'fraud_agent', 'refunds_agent']))
    check('Investigation made no refund', not receipts())
    ask(bob, 'payments-assistant', 'Refund the GBP 1,250 to the customer for PAY-7781.', 'refund')
    small = next(r for r in receipts() if r['payment_id'] == 'PAY-7781')
    check('Small refund issued by specialist', small['amount_gbp'] == 1250 and small['credential_valid'] and small['act'].endswith(':refunds-agent'))
    code, body = bob.ask('payments-assistant', 'The customer has a second failed transfer, PAY-7790 for GBP 25,000. Arrange the refund.')
    check('Large refund reached approval', code == 200 and body.get('result', {}).get('status', {}).get('state') == 'input-required')
    pending = body['result']
    check('No large refund before approval', not any(r['payment_id'] == 'PAY-7790' for r in receipts()))
    pending_evidence = session_evidence(bob, pending)
    gateway_log = kube('-n', 'bank', 'logs', 'deployment/bank-waypoint', '--since=5m')
    check('Large autonomous refusal appears in the same trace', any(
        'trace.id=' + pending_evidence['trace_id'] in line and
        'route=bank/payments' in line and 'http.status=403' in line and
        'src.identity=spiffe://cluster.local/ns/bank/sa/refunds-agent' in line
        for line in gateway_log.splitlines()))
    code, body = bob.approve('payments-assistant', pending)
    check('Bob approved the refund', code == 200 and body.get('result', {}).get('status', {}).get('state') == 'completed')
    approval = approved_record(bob, pending, body['result'], pending_evidence)
    sessions['approval'] = approval['after']
    try:
        switch('on')
        blocked = ask(bob, 'payments-assistant', "Another customer's GBP 900 payment PAY-7795 failed. Refund it.", 'kill')
        check('Kill switch prevented bank write', not any(r['payment_id'] == 'PAY-7795' for r in receipts()))
        log = kube('-n', 'bank', 'logs', 'deployment/agent-refunds-agent-waypoint', '--since=3m')
        check('Kill switch denied at waypoint', 'http.status=403' in log)
    finally:
        switch('off')
    ask(bob, 'payments-assistant', 'Try PAY-7795 again.', 'restore', blocked['contextId'])
    check('Refund restored', any(r['payment_id'] == 'PAY-7795' and r['refund'] == 'ISSUED' for r in receipts()))
    code, result = exchange('bob', 'rogue-agent', 'payments-mcp')
    check('Rogue delegation refused by STS', code >= 400 and 'may_act' in str(result))
    code, result = exchange('carol', 'refunds-agent', 'payments-mcp')
    check('Carol cannot delegate to refunds agent', code >= 400 and 'may_act' in str(result))
    _, result = exchange('bob', 'refunds-agent', 'payments-mcp')
    delegated = claims(result['access_token'])
    check('Delegation retains Bob and specialist', delegated['sub'] == small['sub'] and delegated['act']['sub'].endswith(':refunds-agent'))
    mcp = MCP(result['access_token'])
    check('Payments MCP is stateless', 'Mcp-Session-Id' not in mcp.headers)
    code, _, _ = mcp.call('refund_payment', payment_id='PAY-7790', amount_gbp=25000)
    check('Gateway amount limit is HTTP 403', code == 403)
    _, wrong = exchange('bob', 'customer-agent', 'payments-mcp')
    code, body, _ = MCP(wrong['access_token']).call('refund_payment', payment_id='PAY-7781', amount_gbp=1250)
    check('Wrong specialist cannot refund', code >= 400 or 'error' in body)
    for user, agent, audience, path in [('carol', 'customer-agent', 'customers-mcp', 'customers'),
                                        ('bob', 'fraud-agent', 'fraud-mcp', 'fraud-tools')]:
        _, token = exchange(user, agent, audience)
        probe = MCP(token['access_token'], path)
        check(path + ': MCP is stateless', 'Mcp-Session-Id' not in probe.headers)
    pods = json.loads(kube('-n', 'bank', 'get', 'pods', '-l', 'bank-role=agent', '-o', 'json'))['items']
    check('Five agent pods tested', len(pods) == 5)
    forbidden = ['anthropic-key', 'core-bank-key', 'fraud-vendor-key']
    check('No downstream credential mounted in agents', all(not any(secret in json.dumps(p['spec']) for secret in forbidden) for p in pods))
    placeholder = json.loads(kube('-n', 'bank', 'get', 'secret', 'bank-model-placeholder', '-o', 'json'))
    check('Agent model credential is only a placeholder',
          base64.b64decode(placeholder['data']['ANTHROPIC_API_KEY']) == b'placeholder')
    tool_pods = [p for p in json.loads(kube('-n', 'bank', 'get', 'pods', '-l', 'bank-tool=true', '-o', 'json'))['items']
                 if p['metadata']['labels'].get('app', '').endswith('-mcp')]
    check('Three MCP pods tested', len(tool_pods) == 3)
    check('MCP pods hold no downstream credentials or ServiceAccount tokens',
          all(p['spec'].get('automountServiceAccountToken') is False and
              not any(secret in json.dumps(p['spec']) for secret in forbidden) for p in tool_pods))
    probe = subprocess.run(['kubectl', '--context', CTX, '-n', 'bank', 'exec', 'tools', '--', 'curl', '--max-time', '5', '-sS', '-o', '/dev/null', '-w', '%{http_code}', 'http://core-bank.bank.svc.cluster.local:8001/core'], capture_output=True, text=True)
    check('Direct core-bank path blocked by the mesh', probe.returncode != 0 and probe.stdout.strip() == '000')
    spans = telemetry([bob, carol])
    evidence = {'date': datetime.now(timezone.utc).isoformat(), 'checks': checks,
                'sessions': sessions, 'approval': approval, 'receipts': receipts(),
                'telemetry': spans,
                'delegated_claims': {k: delegated[k] for k in ['sub', 'act', 'aud', 'groups']}}
    Path('/tmp/trustusbank-evidence.json').write_text(json.dumps(evidence, indent=2))
    Path('/tmp/trustusbank-traces.json').write_text(json.dumps({k: v['trace_id'] for k, v in sessions.items()}, indent=2))
    print(f'{len(checks)} checks passed; evidence and trace links updated.', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        Path('/tmp/trustusbank-failed-checks.json').write_text(json.dumps({'checks': checks, 'sessions': sessions}, indent=2))
        raise
