"""Join authenticated kagent events to gateway traces and mock-bank receipts."""
import json
from gateway_client import receipts


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
    assert receipt['act'] == 'system:serviceaccount:bank:payments-assistant'
    assert receipt['traceparent'].split('-')[1] == after['trace_id']
    return {'source': 'Authenticated kagent approval, gateway trace and mock bank',
            'approved_by': client.user, 'approval_id': confirmation['id'],
            'arguments': original['args'], 'before': before, 'after': after,
            'receipt': receipt, 'receipt_trace_id': receipt['traceparent'].split('-')[1]}
