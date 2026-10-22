"""Drive the reference lab's native A2A confirmation messages against the bank."""
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

ORCHESTRATOR = 'http://orchestrator.bank.svc:8080/'
GATEWAY = 'http://bank-gw.bank.svc.cluster.local:8080'
USER = os.environ['BANK_USER_TOKEN']
AGENT = os.environ['BANK_AGENT_TOKEN']


def request(url, token='', data=None):
    args = ['kubectl', '--context', 'kind-trustusbank-lab', '-n', 'bank', 'exec', '-i', 'tools', '--',
            'curl', '--max-time', '180', '-sS', '-w', '\n%{http_code}', url]
    if token:
        args += ['-H', 'authorization: Bearer ' + token]
    if data is not None:
        args += ['-H', 'content-type: application/json', '-d', '@-']
    reply = subprocess.run(args, input=json.dumps(data) if data is not None else None,
                           text=True, capture_output=True, timeout=190)
    if reply.returncode:
        raise RuntimeError(reply.stderr.strip())
    body, status = reply.stdout.rsplit('\n', 1)
    try:
        value = json.loads(body)
    except ValueError:
        value = body
    return int(status), value


def send(token, parts, task_id=None, context_id=None):
    message = {'role': 'user', 'messageId': str(uuid.uuid4()), 'kind': 'message', 'parts': parts}
    if task_id:
        message['taskId'] = task_id
    if context_id:
        message['contextId'] = context_id
    return request(ORCHESTRATOR, token, {'jsonrpc': '2.0', 'id': str(uuid.uuid4()),
                                        'method': 'message/send', 'params': {'message': message}})


def parts(task):
    messages = task.get('history', []) + [task.get('status', {}).get('message') or {}]
    return [part.get('data', {}) for message in messages for part in message.get('parts', [])
            if part.get('kind') == 'data']


def tool_result(task, name):
    responses = [p['response'] for p in parts(task) if p.get('name') == name and 'response' in p]
    assert responses, f'No real {name} result in native task'
    result = responses[-1]
    assert not result.get('isError'), result
    return json.loads(next(c['text'] for c in result['content'] if c['type'] == 'text'))


def audit_count(payment_id):
    status, body = request(GATEWAY + '/core/refunds')
    assert status == 200, (status, body)
    return len([r for r in body['refunds'] if r['payment_id'] == payment_id])


mode = sys.argv[1]
payment_id = 'PAY-25000' if mode == 'approval' else 'PAY-7781'
amount = 25000 if mode == 'approval' else 1250
before = audit_count(payment_id)
prompt = (f'Use get_payment to investigate {payment_id}. Do not refund it.' if mode == 'investigate'
          else f'Check {payment_id} with get_payment, then call refund_payment for exactly {amount} GBP if FAILED. '
               'Call the tool directly; its native confirmation handles any permission request. Return its exact result.')
status, body = send(AGENT, [{'kind': 'text', 'text': prompt}])
assert status == 200 and 'result' in body, (status, body)
task = body['result']
state = task.get('status', {}).get('state')
if mode == 'investigate':
    assert state == 'completed', state
    payment = tool_result(task, 'get_payment')
    assert payment['status'] == 'FAILED'
    assert audit_count(payment_id) == before
    print('Delegation: orchestrator -> ledger-agent')
    print('Payment checked:', json.dumps(payment))
    print('Refunds issued during investigation: 0')
elif mode == 'small':
    assert state == 'completed', state
    payment = tool_result(task, 'get_payment')
    assert payment['status'] == 'FAILED' and payment['amount_gbp'] == 1250, payment
    result = tool_result(task, 'refund_payment')
    assert result['refund'] == 'ISSUED' and result['amount_gbp'] == 1250
    assert audit_count(payment_id) == before + 1
    print('GBP 1250 refund:', json.dumps(result))
    print('Task state:', state)
elif mode == 'approval':
    assert state == 'input-required', state
    payment = tool_result(task, 'get_payment')
    assert payment['status'] == 'FAILED' and payment['amount_gbp'] == 25000, payment
    confirmation = next(p for p in parts(task) if p.get('name') == 'adk_request_confirmation')
    call = confirmation['args']['originalFunctionCall']
    assert call['name'] == 'refund_payment' and call['args']['amount_gbp'] == 25000, call
    assert audit_count(payment_id) == before
    print('GBP 25000 refund: waiting for Bob')
    print('Bank writes before approval: 0')
    # Same function_response payload as agentic-verdict-hitl-kind/scripts/approve.sh.
    decision = [{'kind': 'data', 'metadata': {'kagent_type': 'function_response'},
                 'data': {'id': confirmation['id'], 'name': 'adk_request_confirmation',
                          'response': {'confirmed': True}}}]
    denied, _ = send(AGENT, decision, task['id'], task['contextId'])
    assert denied == 401, denied
    assert audit_count(payment_id) == before
    print('Agent self-approval: HTTP', denied)
    approved, resumed = send(USER, decision, task['id'], task['contextId'])
    assert approved == 200 and 'result' in resumed, (approved, resumed)
    complete = resumed['result']
    assert complete.get('status', {}).get('state') == 'completed', complete.get('status')
    result = tool_result(complete, 'refund_payment')
    assert result['refund'] == 'ISSUED' and result['amount_gbp'] == 25000
    assert audit_count(payment_id) == before + 1
    print('Bob approves with Keycloak: HTTP', approved)
    print('Task state: completed')
    print('GBP 25000 refund:', json.dumps(result))
    claim = USER.split('.')[1]
    human = json.loads(base64.urlsafe_b64decode(claim + '=' * (-len(claim) % 4)))
    evidence = {'timestamp': datetime.now(timezone.utc).isoformat(), 'source': 'native ADK A2A task and mock bank audit',
                'task_id': task['id'], 'context_id': task['contextId'], 'human': human['preferred_username'],
                'human_sub': human['sub'], 'tool': call['name'], 'arguments': call['args'],
                'state_before': state, 'state_after': 'completed', 'bank_writes_before_approval': 0,
                'bank_writes_after_approval': 1, 'result': result}
    Path('/tmp/trustusbank-native-approval.json').write_text(json.dumps(evidence, indent=2))
else:
    raise ValueError('Expected investigate, small or approval')
