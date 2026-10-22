"""MCP access to the existing bank delegation path, without a second approval store."""
import json
from datetime import datetime, timezone
from pathlib import Path
import urllib.parse
import urllib.request
import urllib.error
import uuid
import re
import ssl
import time

from mcp.server.fastmcp import Context, FastMCP
from server import HUMAN_ISSUER, HUMAN_JWKS, delegated_token
import jwt

mcp = FastMCP('bank-delegation', host='0.0.0.0', port=8081,
              stateless_http=True, json_response=True)


def signed_in_user(ctx):
    token = ctx.request_context.request.headers.get('authorization', '').removeprefix('Bearer ')
    if not token:
        raise ValueError('Sign in with Keycloak before using bank tools')
    claims = jwt.decode(token, HUMAN_JWKS.get_signing_key_from_jwt(token).key,
                        algorithms=['RS256'], issuer=HUMAN_ISSUER, options={'verify_aud': False})
    if claims.get('preferred_username') != 'bob' or 'act' in claims or 'payments-ops' not in claims.get('groups', []):
        raise ValueError('Bob payments-ops session required')
    return token, claims


def ledger_rpc(token, user, payload, request_id):
    req = urllib.request.Request('http://ledger-agent.bank.svc:8080/', json.dumps(payload).encode(),
                                 headers={'Content-Type': 'application/json',
                                          'Authorization': 'Bearer ' + token,
                                          'X-User-ID': user['sub'], 'X-Request-ID': request_id})
    with urllib.request.urlopen(req, timeout=180) as r:
        value = json.load(r)
    if 'error' in value or 'result' not in value:
        raise ValueError('Ledger A2A request failed')
    return value['result']


def data_parts(task):
    return [p.get('data', {}) for message in task.get('history', []) + [task.get('status', {}).get('message') or {}]
            for p in message.get('parts', []) if p.get('kind') == 'data']


def receipt(task, tool):
    rows = [p['response'] for p in data_parts(task) if p.get('name') == tool and 'response' in p]
    if not rows or rows[-1].get('isError'):
        raise ValueError('No successful bank tool result in ledger task')
    return json.loads(next(c['text'] for c in rows[-1]['content'] if c['type'] == 'text'))


def start_request(prompt, token, user):
    message_id = str(uuid.uuid4())
    return ledger_rpc(delegated_token(token), user,
                      {'jsonrpc': '2.0', 'id': str(uuid.uuid4()), 'method': 'message/send',
                       'params': {'message': {'kind': 'message', 'role': 'user', 'messageId': message_id,
                                              'parts': [{'kind': 'text', 'text': prompt}]}}}, message_id)


@mcp.tool()
def bank_session_identity(ctx: Context) -> dict:
    """Show the verified person signed in to this bank refund session. Never returns tokens."""
    _, user = signed_in_user(ctx)
    return {'signed_in': user['preferred_username'], 'team': 'payments-ops',
            'identity_provider': 'Keycloak', 'subject': user['sub']}


@mcp.tool()
def investigate_payment(payment_id: str, ctx: Context) -> dict:
    """Delegate a read-only payment investigation through STS and ledger A2A."""
    token, user = signed_in_user(ctx)
    task = start_request(f'Use get_payment to investigate {payment_id}. Do not issue a refund. Return its exact result.', token, user)
    if task.get('status', {}).get('state') != 'completed':
        raise ValueError('Ledger investigation did not complete')
    return {'requested_by': user['preferred_username'], 'delegated_to': 'ledger-agent',
            'payment': receipt(task, 'get_payment'), 'state': 'completed'}


@mcp.tool()
def request_payment_refund(payment_id: str, amount_gbp: float, ctx: Context) -> dict:
    """Delegate the real refund. Small refunds complete; large ones return a native pending confirmation."""
    token, user = signed_in_user(ctx)
    task = start_request(f'Check {payment_id} using get_payment, then call refund_payment for exactly {amount_gbp} GBP if FAILED. '
                         'Call the tool directly; native confirmation handles approval. Return its exact result.', token, user)
    state = task.get('status', {}).get('state')
    if state == 'completed':
        return {'state': state, 'requested_by': user['preferred_username'], 'refund': receipt(task, 'refund_payment')}
    if state != 'input-required':
        raise ValueError('Ledger refund did not complete or request confirmation')
    confirmation = next(p for p in data_parts(task) if p.get('name') == 'adk_request_confirmation')
    call = confirmation['args']['originalFunctionCall']
    return {'state': state, 'payment_id': call['args']['payment_id'], 'amount_gbp': call['args']['amount_gbp'],
            'task_id': task['id'], 'context_id': task['contextId'], 'confirmation_id': confirmation['id']}


@mcp.tool()
def approve_delegated_refund(payment_id: str, amount_gbp: float, task_id: str, context_id: str,
                            confirmation_id: str, ctx: Context) -> dict:
    """Complete the native pending refund after the kagent UI's required human confirmation."""
    token, user = signed_in_user(ctx)
    task = ledger_rpc(delegated_token(token), user,
                      {'jsonrpc': '2.0', 'id': str(uuid.uuid4()), 'method': 'tasks/get',
                       'params': {'id': task_id}}, context_id)
    if task.get('contextId') != context_id or task.get('status', {}).get('state') != 'input-required':
        raise ValueError('No matching pending ledger task')
    confirmation = next(p for p in data_parts(task) if p.get('id') == confirmation_id and p.get('name') == 'adk_request_confirmation')
    call = confirmation['args']['originalFunctionCall']
    if call['name'] != 'refund_payment' or call['args']['payment_id'] != payment_id or call['args']['amount_gbp'] != amount_gbp:
        raise ValueError('Approval arguments do not match the pending refund')
    decision = {'kind': 'data', 'metadata': {'kagent_type': 'function_response'},
                'data': {'id': confirmation_id, 'name': 'adk_request_confirmation', 'response': {'confirmed': True}}}
    task = ledger_rpc(delegated_token(token), user,
                      {'jsonrpc': '2.0', 'id': str(uuid.uuid4()), 'method': 'message/send',
                       'params': {'message': {'kind': 'message', 'role': 'user', 'messageId': str(uuid.uuid4()),
                                              'taskId': task_id, 'contextId': context_id, 'parts': [decision]}}}, context_id)
    if task.get('status', {}).get('state') != 'completed':
        raise ValueError('Approved ledger task did not complete')
    result = receipt(task, 'refund_payment')
    evidence = {'timestamp': datetime.now(timezone.utc).isoformat(),
                'source': 'kagent UI approval tool and native ledger A2A task',
                'human': user['preferred_username'], 'human_sub': user['sub'],
                'task_id': task_id, 'context_id': context_id,
                'confirmation_id': confirmation_id, 'arguments': call['args'],
                'state_before': 'input-required', 'state_after': 'completed',
                'result': result}
    Path('/tmp/trustusbank-ui-approval.json').write_text(json.dumps(evidence))
    return {'state': 'completed', 'approved_by': user['preferred_username'], 'refund': result}


def kube(path, method='GET', body=None, dry_run=False):
    """Use this workload's namespaced operator role, never a host kubeconfig."""
    token = Path('/var/run/secrets/kubernetes.io/serviceaccount/token').read_text().strip()
    if dry_run:
        path += ('&' if '?' in path else '?') + 'dryRun=All'
    headers = {'Authorization': 'Bearer ' + token,
               'Content-Type': 'application/merge-patch+json' if method == 'PATCH' else 'application/json'}
    req = urllib.request.Request('https://kubernetes.default.svc' + path,
                                 json.dumps(body).encode() if body is not None else None,
                                 headers=headers, method=method)
    ca = ssl.create_default_context(cafile='/var/run/secrets/kubernetes.io/serviceaccount/ca.crt')
    with urllib.request.urlopen(req, context=ca, timeout=15) as response:
        value = response.read().decode()
    return value if path.split('?')[0].endswith('/log') else json.loads(value)


def patch(path, body):
    kube(path, 'PATCH', body, dry_run=True)
    return kube(path, 'PATCH', body)


@mcp.tool()
def try_rogue_delegation(ctx: Context) -> dict:
    """Try the copied delegation with rogue-agent and return the real STS refusal. No refund."""
    token, user = signed_in_user(ctx)
    own = Path('/var/run/secrets/kubernetes.io/serviceaccount/token').read_text().strip()
    audience = jwt.decode(own, options={'verify_signature': False})['aud']
    rogue = kube('/api/v1/namespaces/bank/serviceaccounts/rogue-agent/token', 'POST',
                 {'apiVersion': 'authentication.k8s.io/v1', 'kind': 'TokenRequest',
                  'spec': {'audiences': audience if isinstance(audience, list) else [audience],
                           'expirationSeconds': 600}})['status']['token']
    data = urllib.parse.urlencode({
        'grant_type': 'urn:ietf:params:oauth:grant-type:token-exchange',
        'subject_token_type': 'urn:ietf:params:oauth:token-type:jwt',
        'subject_token': delegated_token(token),
        'actor_token_type': 'urn:ietf:params:oauth:token-type:jwt',
        'actor_token': rogue, 'audience': 'payments-mcp'}).encode()
    try:
        with urllib.request.urlopen('http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth2/token', data, timeout=15) as r:
            result = json.load(r)
    except urllib.error.HTTPError as error:
        result = json.loads(error.read())
    if result.get('error') != 'unauthorized_client':
        raise ValueError('Expected the rogue delegation to be refused')
    return {'requested_by': user['preferred_username'], 'status': 'REFUSED',
            'refused_by': 'Solo STS', 'error': result['error'],
            'reason': result.get('error_description', '')}


def probe(url):
    with urllib.request.urlopen(url, timeout=3) as response:
        return response.status


@mcp.tool()
def exercise_ledger_stop(ctx: Context) -> dict:
    """Block one Ready ledger instance through Istio, prove refusal, then restore it. Leave the assistant running."""
    _, user = signed_in_user(ctx)
    pods = kube('/api/v1/namespaces/bank/pods?labelSelector=bank-agent%3Dledger-agent')['items']
    pod = next(p for p in pods if not p['metadata'].get('deletionTimestamp') and
               any(c['type'] == 'Ready' and c['status'] == 'True' for c in p.get('status', {}).get('conditions', [])))
    name, uid = pod['metadata']['name'], pod['metadata']['uid']
    url = 'http://' + pod['status']['podIP'] + ':8080/.well-known/agent-card.json'
    before = probe(url)
    if before != 200:
        raise ValueError('Selected ledger instance is not reachable before the stop')
    policy = '/apis/security.istio.io/v1/namespaces/bank/authorizationpolicies/kill-ledger-instance'
    patch(policy, {'spec': {'action': 'DENY', 'rules': [{}],
                           'selector': {'matchLabels': {'trustusbank-instance': uid}}}})
    pod_path = '/api/v1/namespaces/bank/pods/' + name
    blocked = False
    try:
        patch(pod_path, {'metadata': {'labels': {'trustusbank-instance': uid}}})
        for _ in range(15):
            time.sleep(1)
            try:
                probe(url)
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                blocked = True
                break
        if not blocked:
            raise ValueError('The selected ledger instance was not blocked')
    finally:
        patch(pod_path, {'metadata': {'labels': {'trustusbank-instance': None}}})
    restored = None
    for _ in range(15):
        try:
            restored = probe(url)
            break
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            time.sleep(1)
    if restored != 200:
        raise ValueError('Ledger instance has not recovered after label restoration')
    return {'requested_by': user['preferred_username'], 'instance_uid': uid,
            'enforced_by': 'Istio OSS ambient/ztunnel', 'before_http': before,
            'blocked': blocked, 'restored_http': restored,
            'assistant_http': probe('http://orchestrator.bank.svc:8080/.well-known/agent-card.json')}


@mcp.tool()
def get_refund_evidence(ctx: Context) -> dict:
    """Join the real UI-approved receipt to the gateway refund log for the signed-in person."""
    _, user = signed_in_user(ctx)
    approval = json.loads(Path('/tmp/trustusbank-ui-approval.json').read_text())
    if approval['human_sub'] != user['sub']:
        raise ValueError('The saved approval belongs to another signed-in person')
    pods = kube('/api/v1/namespaces/bank/pods')['items']
    gateway = next(p for p in pods if p['metadata']['name'].startswith('bank-gw-') and not p['metadata'].get('deletionTimestamp'))
    logs = kube('/api/v1/namespaces/bank/pods/' + gateway['metadata']['name'] + '/log?sinceSeconds=86400')
    matches = []
    for line in logs.splitlines():
        if 'gen_ai.tool.name=refund_payment' not in line:
            continue
        fields = {}
        for key, value in re.findall(r'([\w.]+)=("(?:\\.|[^"\\])*"|\S+)', line):
            fields[key] = json.loads(value) if value.startswith('"') else value
        if fields.get('audit.call') == approval['context_id'] and fields.get('audit.sub') == user['sub']:
            matches.append({k: fields[k] for k in ('http.status', 'gen_ai.tool.name', 'audit.user', 'audit.sub', 'audit.actor', 'audit.call')})
    if not matches:
        raise ValueError('No gateway refund log matches this approval and human subject')
    return {'requested_by': user['preferred_username'], 'approval': approval,
            'gateway_call': matches[-1], 'context_matches': True}
