"""Keycloak-authenticated A2A client for captures; never prints bearer tokens."""
import argparse
import contextlib
import json
import socket
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

CTX = 'kind-trustusbank-lab'


@contextlib.contextmanager
def forward(namespace, service, remote):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    process = subprocess.Popen(['kubectl', '--context', CTX, '-n', namespace,
                                'port-forward', 'svc/' + service, f'{port}:{remote}'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('Port-forward exited: ' + service)
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=0.3):
                    break
            except OSError:
                time.sleep(0.2)
        else:
            raise TimeoutError('Port-forward did not start: ' + service)
        yield f'http://127.0.0.1:{port}'
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def http(url, data=None, token=None):
    headers = {}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if isinstance(data, dict):
        data = json.dumps(data).encode()
        headers['Content-Type'] = 'application/json'
    elif isinstance(data, bytes):
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
    request = urllib.request.Request(url, data=data, headers=headers)
    try:
        response = urllib.request.urlopen(request, timeout=300)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        text = response.read().decode()
        try:
            body = json.loads(text)
        except ValueError:
            body = {'text': text}
        return response.status, body


class Client:
    def __init__(self, user='bob'):
        self.user = user
        self.issued_tokens = []
        self._authenticate()

    def _authenticate(self):
        with forward('keycloak', 'keycloak', 8080) as base:
            status, body = http(base + '/realms/bank/protocol/openid-connect/token',
                                urllib.parse.urlencode({'grant_type': 'password',
                                    'client_id': 'payments-ops', 'username': self.user,
                                    'password': 'password'}).encode())
        if status != 200:
            raise RuntimeError(f'Sign-in failed for {self.user}: HTTP {status}')
        self.token = body['access_token']
        self.issued_tokens.append(self.token)
        self.refresh_at = time.monotonic() + max(0, body.get('expires_in', 300) - 30)

    def _refresh_if_needed(self):
        if time.monotonic() >= self.refresh_at:
            self._authenticate()

    def call(self, agent, method, params):
        self._refresh_if_needed()
        with forward('kagent', 'kagent-controller', 8083) as base:
            return http(base + f'/api/a2a/bank/{agent}/',
                        {'jsonrpc': '2.0', 'id': str(uuid.uuid4()), 'method': method,
                         'params': params}, self.token)

    def ask(self, agent, prompt, context_id=None):
        message = {'role': 'user', 'messageId': str(uuid.uuid4()),
                   'parts': [{'kind': 'text', 'text': prompt}]}
        if context_id:
            message['contextId'] = context_id
        return self.call(agent, 'message/send', {'message': message})

    def approve(self, agent, task):
        if task['status']['state'] != 'input-required':
            raise ValueError('Task is not awaiting approval')
        confirmation = next(p['data'] for p in task['status']['message']['parts']
                            if p.get('data', {}).get('name') == 'adk_request_confirmation')
        original = confirmation['args']['originalFunctionCall']
        if original['name'] != 'refund_payment_with_approval':
            raise ValueError('Expected the refund approval tool, got ' + original['name'])
        return self.call(agent, 'message/send', {'message': {
            'kind': 'message', 'role': 'user', 'messageId': str(uuid.uuid4()),
            'taskId': task['id'], 'contextId': task['contextId'],
            'parts': [{'kind': 'data', 'metadata': {'kagent_type': 'function_response'},
                       'data': {'id': confirmation['id'], 'name': 'adk_request_confirmation',
                                'response': {'confirmed': True}}}]}})

    def session(self, context_id):
        self._refresh_if_needed()
        with forward('kagent', 'kagent-controller', 8083) as base:
            code, body = http(base + '/api/sessions/' + context_id, token=self.token)
        if code != 200 or body.get('error'):
            raise RuntimeError('Unable to retrieve the authenticated session')
        return body['data']


def texts(value):
    if isinstance(value, dict):
        if value.get('kind') == 'text':
            yield value['text']
        for child in value.values():
            yield from texts(child)
    elif isinstance(value, list):
        for child in value:
            yield from texts(child)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('user', choices=['bob', 'carol', 'sarah', 'alice'])
    parser.add_argument('prompt')
    parser.add_argument('--agent', default='payments-assistant')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    code, body = Client(args.user).ask(args.agent, args.prompt)
    print(json.dumps({'http_status': code, 'body': body}, indent=2) if args.json
          else f'HTTP {code}\n' + '\n'.join(dict.fromkeys(texts(body))))
    if code >= 400 or 'error' in body or body.get('result', {}).get('status', {}).get('state') == 'failed':
        raise SystemExit(1)
