"""A completed model turn is not proof that customer records were retrieved."""
import json
import unittest

from evidence import delegated_tool_result


class FakeClient:
    def __init__(self, result):
        self.result = result

    def session(self, context_id):
        assert context_id == 'customer-session'
        return {'events': [{'created_at': '2026-10-22T16:00:00Z', 'data': json.dumps({
            'content': {'parts': [{'function_response': {
                'name': 'get_customer', 'response': self.result,
            }}]},
        })}]}


PARENT = {'responses': [{'name': 'bank__NS__customer_agent',
                         'response': {'subagent_session_id': 'customer-session'}}]}


class CustomerEvidenceTests(unittest.TestCase):
    def test_reads_the_actual_mcp_result(self):
        record = {'payment_id': 'PAY-7781', 'debit_status': 'DEBITED', 'amount_gbp': 1250}
        client = FakeClient({'content': [{'type': 'text', 'text': json.dumps(record)}], 'isError': False})
        self.assertEqual(delegated_tool_result(client, PARENT, 'customer-agent', 'get_customer'), record)

    def test_a_completed_prose_reply_is_not_a_tool_result(self):
        parent = {'responses': [{'name': 'bank__NS__customer_agent',
                                 'response': {'result': 'Customer records are unavailable.'}}]}
        with self.assertRaises(AssertionError):
            delegated_tool_result(FakeClient({}), parent, 'customer-agent', 'get_customer')

    def test_a_failed_tool_is_not_a_customer_record(self):
        client = FakeClient({'content': [{'type': 'text', 'text': '{}'}], 'isError': True})
        with self.assertRaises(AssertionError):
            delegated_tool_result(client, PARENT, 'customer-agent', 'get_customer')

    def test_a_connection_error_is_not_a_customer_record(self):
        with self.assertRaises(AssertionError):
            delegated_tool_result(FakeClient({'error': 'MCP session timed out'}), PARENT,
                                  'customer-agent', 'get_customer')


if __name__ == '__main__':
    unittest.main()
