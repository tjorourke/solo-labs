"""Disposable payment tools. The gateway owns token verification and tool policy."""
from mcp.server.fastmcp import FastMCP
import json
import urllib.request
import urllib.error

mcp = FastMCP('payments', host='0.0.0.0', port=8000, stateless_http=True, json_response=True)


@mcp.tool()
def get_payment(payment_id: str) -> dict:
    return {'payment_id': payment_id, 'status': 'FAILED', 'amount_gbp': 25000 if payment_id == 'PAY-25000' else 1250,
            'reason': 'beneficiary bank timeout'}


@mcp.tool()
def refund_payment(payment_id: str, amount_gbp: float) -> dict:
    if amount_gbp <= 0:
        raise ValueError('Refund must be positive')
    request = urllib.request.Request(
        'http://bank-gw.bank.svc.cluster.local:8080/core/refund',
        data=json.dumps({'payment_id': payment_id, 'amount_gbp': amount_gbp}).encode(),
        headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=10) as reply:
            return json.load(reply)
    except urllib.error.HTTPError as error:
        raise ValueError(f'Core bank refused refund: HTTP {error.code}') from error


mcp.run(transport='streamable-http')
