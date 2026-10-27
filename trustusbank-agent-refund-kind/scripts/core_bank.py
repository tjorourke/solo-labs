"""Disposable core-banking mock. Vault validates its opaque credential per call."""
import json
import urllib.request
import urllib.error
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

refunds = []


class Bank(BaseHTTPRequestHandler):
    def valid_credential(self):
        token = self.headers.get('Authorization', '').removeprefix('Bearer ')
        req = urllib.request.Request('http://vault.vault.svc:8200/v1/auth/token/lookup-self',
                                     headers={'X-Vault-Token': token})
        try:
            with urllib.request.urlopen(req, timeout=3) as reply:
                return reply.status == 200
        except (urllib.error.URLError, TimeoutError):
            return False

    def do_GET(self):
        valid = self.valid_credential()
        self.send_response(200 if valid else 401)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'refunds': refunds} if valid else {'credential_valid': False}).encode())

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        valid = self.valid_credential()
        self.send_response(200 if valid else 401)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        result = {'credential_valid': valid, 'payment_id': body.get('payment_id', 'PAY-7781')}
        if valid and self.path == '/core/refund':
            previous = next((r for r in refunds if r['payment_id'] == result['payment_id']), None)
            if previous:
                result = {**previous, 'idempotent': True}
            else:
                result.update(refund='ISSUED', amount_gbp=body['amount_gbp'], mock=True,
                              sub=self.headers.get('X-Bank-Sub'),
                              act=self.headers.get('X-Bank-Actor'),
                              user=self.headers.get('X-Bank-User'),
                              traceparent=self.headers.get('traceparent'),
                              timestamp=datetime.now(timezone.utc).isoformat())
                refunds.append(result)
        self.wfile.write(json.dumps(result).encode())


HTTPServer(('0.0.0.0', 8001), Bank).serve_forever()
