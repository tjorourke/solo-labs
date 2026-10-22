"""Disposable fraud vendor. The expected key is only mounted in this verifier."""
import hmac
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer


class Vendor(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'healthy')

    def do_POST(self):
        valid = hmac.compare_digest(self.headers.get('X-Api-Key', ''), os.environ['VENDOR_API_KEY'])
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        self.send_response(200 if valid else 401)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'payment_id': body.get('payment_id'),
                                    'risk': 'LOW' if valid else None,
                                    'credential_valid': valid, 'mock': True}).encode())


if __name__ == '__main__':
    HTTPServer(('0.0.0.0', 8002), Vendor).serve_forever()
