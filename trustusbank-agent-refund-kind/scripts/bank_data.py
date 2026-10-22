"""Synthetic payment records shared by the lab's three MCP servers."""
PAYMENTS = {
    'PAY-7781': {'customer_id': 'C-1042', 'customer': 'Morgan Taylor', 'amount_gbp': 1250},
    'PAY-7790': {'customer_id': 'C-1042', 'customer': 'Morgan Taylor', 'amount_gbp': 25000},
    'PAY-7795': {'customer_id': 'C-2048', 'customer': 'Jamie Patel', 'amount_gbp': 900},
}


def payment(payment_id):
    if payment_id not in PAYMENTS:
        raise ValueError('Unknown payment: ' + payment_id)
    return {'payment_id': payment_id, 'status': 'FAILED', 'debit_status': 'DEBITED',
            'reason': 'beneficiary bank timeout', **PAYMENTS[payment_id]}
