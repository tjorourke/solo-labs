"""Read-only readiness check: require real records, never trust agent prose."""
from client import Client
from gateway_client import MCP, exchange
from evidence import delegated_tool_result, session_evidence


def main():
    code, token = exchange('carol', 'customer-agent', 'customers-mcp')
    if code != 200:
        raise RuntimeError(f'STS exchange failed: HTTP {code}')
    code, body, _ = MCP(token['access_token'], 'customers').call(
        'get_customer', payment_id='PAY-7781')
    if code != 200 or body.get('error') or body.get('result', {}).get('isError'):
        raise RuntimeError('Authenticated customer MCP lookup failed')
    carol = Client('carol')
    code, body = carol.ask('customer-service-assistant',
        'A customer says payment PAY-7781 failed this morning and the money has left their account. What happened?')
    if code != 200 or body.get('error') or body['result']['status']['state'] != 'completed':
        raise RuntimeError('Carol enquiry did not complete')
    record = delegated_tool_result(carol, session_evidence(carol, body['result']),
                                   'customer-agent', 'get_customer')
    if not (record['payment_id'] == 'PAY-7781' and record['customer'] == 'Morgan Taylor'
            and record['amount_gbp'] == 1250 and record['debit_status'] == 'DEBITED'):
        raise RuntimeError('Carol enquiry did not return the expected record')
    print('Ready: STS exchange, authenticated MCP and Carol A2A enquiry returned PAY-7781.')


if __name__ == '__main__':
    main()
