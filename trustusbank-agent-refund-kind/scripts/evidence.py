"""Join authenticated kagent events to gateway traces and mock-bank receipts."""
import json
from gateway_client import receipts


def tool_result(session, name):
    """Extract an actual successful MCP result from this conversation."""
    for response in reversed(session['responses']):
        if response.get('name') != name:
            continue
        result = response.get('response', {})
        if result.get('error') or result.get('isError'):
            continue
        for item in result.get('content', []):
            if item.get('type') == 'text':
                return json.loads(item['text'])
    raise AssertionError('No successful ' + name + ' result')


def delegated_tool_result(client, parent, agent_name, tool_name):
    """Read the actual successful MCP result, not the assistant's prose."""
    children = [r['response']['subagent_session_id'] for r in parent['responses']
                if r.get('name', '').endswith(agent_name.replace('-', '_'))
                and r.get('response', {}).get('subagent_session_id')]
    for child in reversed(children):
        events = client.session(child)['events']
        for event in sorted(events, key=lambda e: e['created_at'], reverse=True):
            body = json.loads(event['data'])
            for part in (body.get('content') or {}).get('parts', []):
                response = part.get('function_response') or {}
                if response.get('name') != tool_name:
                    continue
                result = response.get('response', {})
                if result.get('isError') or result.get('error'):
                    continue
                for content in result.get('content', []):
                    if content.get('type') == 'text':
                        value = json.loads(content['text'])
                        if isinstance(value, dict):
                            return value
    raise AssertionError(f'{agent_name} did not return a successful {tool_name} result')


def session_evidence(client, task):
    data = client.session(task['contextId'])
    trace_ids = []
    calls, responses = [], []
    for event in sorted(data['events'], key=lambda event: event['created_at']):
        body = json.loads(event['data'])
        # Read only the trace header. Never persist the session's bearer header.
        trace = body.get('actions', {}).get('state_delta', {}).get('headers', {}).get('traceparent')
        if trace:
            trace_id = trace.split('-')[1]
            if trace_id not in trace_ids:
                trace_ids.append(trace_id)
        for part in (body.get('content') or {}).get('parts', []):
            if part.get('function_call'):
                calls.append(part['function_call'])
            if part.get('function_response'):
                responses.append(part['function_response'])
    return {'user': client.user, 'task_id': task['id'], 'context_id': task['contextId'],
            'state': task['status']['state'], 'trace_id': trace_ids[-1] if trace_ids else None,
            'trace_ids': trace_ids,
            'calls': calls, 'responses': responses}


def approved_record(client, pending, completed, before=None):
    before = before or session_evidence(client, pending)
    after = session_evidence(client, completed)
    confirmation = next(p['data'] for p in pending['status']['message']['parts']
                        if p.get('data', {}).get('name') == 'adk_request_confirmation')
    original = confirmation['args']['originalFunctionCall']
    assert original['name'] == 'refund_payment_with_approval'
    payment_id = original['args']['payment_id']
    receipt = next(r for r in receipts() if r['payment_id'] == payment_id)
    assert receipt['refund'] == 'ISSUED' and receipt['credential_valid']
    assert receipt['act'] == 'system:serviceaccount:bank:payments-manager'
    assert receipt['user'] == client.user == 'sarah'
    assert receipt['traceparent'].split('-')[1] == after['trace_id']
    return {'source': 'Authenticated kagent approval, gateway trace and mock bank',
            'approved_by': client.user, 'approval_id': confirmation['id'],
            'arguments': original['args'], 'before': before, 'after': after,
            'receipt': receipt, 'receipt_trace_id': receipt['traceparent'].split('-')[1]}
