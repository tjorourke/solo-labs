"""The assistant's identity boundary. Native ADK owns the ledger's approval state."""
import json
import uuid
import urllib.request
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import jwt

STS = 'http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777'
JWKS = jwt.PyJWKClient(STS + '/.well-known/jwks.json')
HUMAN_ISSUER = 'http://keycloak.keycloak.svc.cluster.local:8080/realms/bank'
HUMAN_JWKS = jwt.PyJWKClient(HUMAN_ISSUER + '/protocol/openid-connect/certs')


def delegated_token(subject):
    actor = Path('/var/run/secrets/kubernetes.io/serviceaccount/token').read_text().strip()
    data = urllib.parse.urlencode({'grant_type': 'urn:ietf:params:oauth:grant-type:token-exchange',
                                   'subject_token_type': 'urn:ietf:params:oauth:token-type:jwt',
                                   'subject_token': subject,
                                   'actor_token_type': 'urn:ietf:params:oauth:token-type:jwt',
                                   'actor_token': actor, 'audience': 'ledger-agent'}).encode()
    with urllib.request.urlopen(STS + '/oauth2/token', data, timeout=10) as reply:
        return json.load(reply)['access_token']


class Assistant(BaseHTTPRequestHandler):
    def reply(self, status, body):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(body.encode())

    def do_GET(self):
        self.reply(200, json.dumps({
            'name': 'orchestrator', 'description': 'TrustUs Bank payment assistant',
            'url': 'http://orchestrator.bank.svc:8080/', 'version': '1.0',
            'capabilities': {'streaming': False}, 'defaultInputModes': ['text'],
            'defaultOutputModes': ['text'], 'skills': [{'id': 'refund', 'name': 'Payment investigation',
                'description': 'Ask the refunds agent to investigate a payment', 'tags': ['payments']}],
        }))

    def do_POST(self):
        try:
            request = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        except ValueError:
            self.reply(400, json.dumps({'error': 'Invalid JSON'}))
            return
        message = request.get('params', {}).get('message', {})
        continuation = bool(message.get('taskId') or message.get('contextId')) or any(
            isinstance(p.get('data'), dict) and p['data'].get('name') == 'adk_request_confirmation'
            for p in message.get('parts', []) if isinstance(p, dict))
        try:
            token = self.headers.get('Authorization', '').removeprefix('Bearer ')
            if continuation:
                claims = jwt.decode(token, HUMAN_JWKS.get_signing_key_from_jwt(token).key,
                                    algorithms=['RS256'], issuer=HUMAN_ISSUER,
                                    options={'verify_aud': False})
                if 'act' in claims or claims.get('preferred_username') != 'priya' or 'payments-ops' not in claims.get('groups', []):
                    raise ValueError('Human approval token required')
            else:
                claims = jwt.decode(token, JWKS.get_signing_key_from_jwt(token).key,
                                    algorithms=['RS256'], audience='ledger-agent',
                                    issuer=STS.removeprefix('http://'))
                if claims['act']['sub'] != 'system:serviceaccount:bank:orchestrator':
                    raise ValueError('Expected orchestrator actor')
        except Exception:
            self.reply(401, json.dumps({'error': 'Human approval token required' if continuation
                                       else 'Exchanged human token required'}))
            return
        try:
            if request.get('method') != 'message/send':
                raise ValueError('Only A2A message/send is supported')
            if continuation:
                token = delegated_token(token)
            headers = {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token,
                       'X-User-ID': claims['sub'],
                       'X-Request-ID': message.get('contextId') or message.get('messageId', str(uuid.uuid4()))}
            req = urllib.request.Request('http://ledger-agent.bank.svc:8080/',
                                         json.dumps(request).encode(), headers=headers)
            with urllib.request.urlopen(req, timeout=180) as reply:
                self.reply(reply.status, reply.read().decode())
        except Exception as error:
            self.reply(502, json.dumps({'error': str(error)}))


ThreadingHTTPServer(('0.0.0.0', 8080), Assistant).serve_forever()
