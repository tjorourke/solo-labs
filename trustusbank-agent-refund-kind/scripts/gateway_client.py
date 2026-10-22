"""Deterministic probes through the mesh, with request credentials on stdin."""
import base64
import json
import subprocess
import urllib.parse
import uuid
from client import CTX, Client


def kube(*args, data=None):
    return subprocess.check_output(['kubectl', '--context', CTX, *args], input=data, text=True)


def request(url, data=None, headers=None):
    config = ''.join('header = ' + json.dumps(k + ': ' + v) + '\n'
                     for k, v in (headers or {}).items())
    if data is not None:
        config += 'data = ' + json.dumps(data) + '\n'
    raw = kube('-n', 'bank', 'exec', '-i', 'tools', '--', 'curl', '-sS', '--max-time', '30',
               '-i', '-K', '-', url, data=config)
    head, body = raw.split('\n\n', 1)
    code = int(head.split()[1])
    response_headers = {}
    for line in head.splitlines()[1:]:
        if ':' in line:
            key, val = line.split(':', 1)
            response_headers[key.lower()] = val.strip()
    try:
        result = json.loads(body)
    except ValueError:
        messages = [line[6:] for line in body.splitlines() if line.startswith('data: ')]
        result = json.loads(messages[-1]) if messages else {'text': body}
    return code, result, response_headers


def claims(token):
    payload = token.split('.')[1]
    return json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))


def receipts():
    # The payments pod is allowed to reach /core. No credential is passed to it.
    value = kube('-n', 'bank', 'exec', 'deployment/payments-mcp', '--', 'python', '-c',
                 'import urllib.request; print(urllib.request.urlopen("http://bank-gw.bank.svc.cluster.local:8080/core/refunds",timeout=15).read().decode())')
    return json.loads(value)['refunds']


def exchange(user, agent, audience):
    token = Client(user).token
    actor = kube('-n', 'bank', 'create', 'token', agent, '--duration=10m').strip()
    data = urllib.parse.urlencode({'grant_type': 'urn:ietf:params:oauth:grant-type:token-exchange',
            'subject_token_type': 'urn:ietf:params:oauth:token-type:jwt', 'subject_token': token,
            'actor_token_type': 'urn:ietf:params:oauth:token-type:jwt', 'actor_token': actor,
            'audience': audience})
    code, result, _ = request('http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth2/token',
                              data, {'Content-Type': 'application/x-www-form-urlencoded'})
    return code, result


class MCP:
    def __init__(self, token, path='mcp'):
        self.url = 'http://bank-gw.bank.svc.cluster.local:8080/' + path
        self.headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
                        'Accept': 'application/json, text/event-stream'}
        code, result, headers = self.rpc('initialize', {'protocolVersion': '2025-03-26',
                                  'capabilities': {}, 'clientInfo': {'name': 'bank-test', 'version': '2'}})
        if code != 200:
            raise RuntimeError(f'MCP initialise: HTTP {code}, {result}')
        if 'mcp-session-id' in headers:
            self.headers['Mcp-Session-Id'] = headers['mcp-session-id']

    def rpc(self, method, params):
        return request(self.url, json.dumps({'jsonrpc': '2.0', 'id': str(uuid.uuid4()),
                                             'method': method, 'params': params}), self.headers)

    def call(self, name, **arguments):
        return self.rpc('tools/call', {'name': name, 'arguments': arguments})


if __name__ == '__main__':
    _, result = exchange('bob', 'refunds-agent', 'payments-mcp')
    token = result['access_token']
    print('Delegated claims:', json.dumps(claims(token)))
    mcp = MCP(token)
    for method, params in [('tools/list', {}), ('tools/call', {'name': 'refund_payment',
                               'arguments': {'payment_id': 'PAY-7781', 'amount_gbp': 1250}})]:
        code, body, _ = mcp.rpc(method, params)
        print(method, code, json.dumps(body))
