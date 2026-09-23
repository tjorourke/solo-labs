import importlib.util
from pathlib import Path
import json
import unittest

spec = importlib.util.spec_from_file_location('dashboard', Path(__file__).with_name('30-dashboard.py'))
dashboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dashboard)


def opa(trace, span, task, prompt, user='bob'):
    return json.dumps({
        'timestamp': '2026-09-19T13:49:00Z', 'decision_id': trace + span,
        'input': {'attributes': {
            'metadataContext': {'filterMetadata': {'envoy.filters.http.jwt_authn': {'jwt_payload': {'sub': user}}}},
            'request': {'http': {'method': 'POST', 'headers': {
                'traceparent': f'00-{trace}-{span}-01', 'x-selected-model': task},
                'body': json.dumps({'messages': [{'role': 'user', 'content': prompt}]})}}}},
        'result': {'allowed': True, 'headers': {'x-model-pool': 'private',
                   'x-model-class': task, 'x-routing-reason': task}},
    })


def access(trace, span, model, status=200):
    return (f'2026-09-19T13:49:05Z info request http.path=/v1/chat/completions '
            f'trace.id={trace} span.id={span} jwt.sub=bob http.status={status} '
            f'gen_ai.response.model={model} duration=100ms')


# What Claude Code posts when it names a conversation, not anything the person typed.
TITLE_PROMPT = ('Please write a 5-10 word succinct title for an agent chat session. '
                'Write the title in the predominant language of the conversation.')


class LogLineTests(unittest.TestCase):
    def test_a_line_bigger_than_one_chunk_still_arrives_whole(self):
        body = b'{"decision_id":"x"}' + b'y' * 200
        chunks = [body[:80], body[80:150], body[150:] + b'\n' + b'next\n', b'']

        class Stream:
            def read(self, _n):
                return chunks.pop(0)

        lines = list(dashboard.read_log_lines(Stream(), chunk=64))
        self.assertEqual(lines, [body.decode(), 'next'])


class CorrelationTests(unittest.TestCase):
    def setUp(self):
        dashboard.cards.clear()
        dashboard.dropped.clear()
        self.a, self.b = 'a' * 32, 'b' * 32
        self.x, self.y = '1' * 16, '2' * 16

    def test_parallel_same_user_cannot_swap_models(self):
        dashboard.on_opa(opa(self.a, self.x, 'telco', '5G research'))
        dashboard.on_opa(opa(self.b, self.y, 'code_modification', 'Main agent'))
        dashboard.on_gateway(access(self.a, self.x, 'mistral'))
        dashboard.on_gateway(access(self.b, self.y, 'qwen'))
        self.assertEqual([(c['task'], c['answered_by']) for c in dashboard.cards],
                         [('telco', 'mistral'), ('code_modification', 'qwen')])

    def test_completion_before_policy_event_and_duplicates(self):
        dashboard.on_gateway(access(self.a, self.x, 'mistral', 400))
        dashboard.on_opa(opa(self.a, self.x, 'telco', '5G research'))
        dashboard.on_gateway(access(self.a, self.x, 'mistral', 400))
        self.assertEqual(len(dashboard.cards), 1)
        self.assertEqual(dashboard.cards[0]['status'], '400')
        self.assertEqual(dashboard.cards[0]['task'], 'telco')

    def test_same_trace_different_spans_remain_separate(self):
        dashboard.on_opa(opa(self.a, self.x, 'telco', 'same prompt'))
        dashboard.on_opa(opa(self.a, self.y, 'code_modification', 'same prompt'))
        dashboard.on_gateway(access(self.a, self.y, 'qwen'))
        self.assertNotIn('status', dashboard.cards[0])
        self.assertEqual(dashboard.cards[1]['answered_by'], 'qwen')

    def test_missing_trace_never_falls_back_to_user_or_time(self):
        dashboard.on_opa(opa(self.a, self.x, 'telco', '5G research'))
        dashboard.on_gateway(access('', '', 'qwen'))
        self.assertEqual(len(dashboard.cards), 2)
        self.assertNotIn('answered_by', dashboard.cards[0])
        self.assertEqual(dashboard.cards[1]['correlation'], 'unmatched')

    def test_zero_trace_is_not_a_valid_correlation(self):
        self.assertIsNone(dashboard.request_key('0' * 32, self.x))
        self.assertIsNone(dashboard.request_key(self.a, '0' * 16))

    def test_housekeeping_never_reaches_the_screen(self):
        # The client naming the conversation, and the access log for the same request
        # arriving afterwards. Neither may leave a row behind.
        dashboard.on_opa(opa(self.a, self.x, 'code_review', TITLE_PROMPT))
        dashboard.on_gateway(access(self.a, self.x, 'qwen'))
        self.assertEqual(dashboard.cards, [])

    def test_housekeeping_card_is_withdrawn_when_the_log_arrives_first(self):
        dashboard.on_gateway(access(self.a, self.x, 'qwen'))
        self.assertEqual(len(dashboard.cards), 1)
        dashboard.on_opa(opa(self.a, self.x, 'code_review', TITLE_PROMPT))
        self.assertEqual(dashboard.cards, [])

    def test_a_real_prompt_beside_a_dropped_one_is_untouched(self):
        dashboard.on_opa(opa(self.a, self.x, 'code_review', TITLE_PROMPT))
        dashboard.on_opa(opa(self.b, self.y, 'finance', 'Duration risk in this portfolio?'))
        dashboard.on_gateway(access(self.b, self.y, 'mistral'))
        self.assertEqual([(c['task'], c['answered_by']) for c in dashboard.cards],
                         [('finance', 'mistral')])

    def test_reminders_hidden_but_pasted_question_preserved(self):
        body = json.dumps({'messages': [{'role': 'user', 'content':
            '<system-reminder>private rules</system-reminder>'
            '<pasted_content id="a">How does 5G slicing work?</pasted_content>'}]})
        _, question, _, _ = dashboard.read_prompt(body)
        self.assertEqual(question, 'How does 5G slicing work?')

    def test_an_enrolled_laptop_is_filed_under_its_login_not_a_uuid(self):
        # An Agentdesktop token carries a Keycloak UUID in sub and the login in email.
        uuid_sub = '11111111-2222-3333-4444-555555555555'
        decision = json.loads(opa(self.a, self.x, 'finance', 'Duration risk?'))
        payload = (decision['input']['attributes']['metadataContext']['filterMetadata']
                   ['envoy.filters.http.jwt_authn']['jwt_payload'])
        payload['sub'] = uuid_sub
        payload['email'] = 'bob@corp.example'
        dashboard.on_opa(json.dumps(decision))
        self.assertEqual(dashboard.cards[0]['user'], 'bob')
        # The access log only carries the raw sub, so it must not undo that.
        dashboard.on_gateway(access(self.a, self.x, 'mistral').replace('jwt.sub=bob', f'jwt.sub={uuid_sub}'))
        self.assertEqual(dashboard.cards[0]['user'], 'bob')


if __name__ == '__main__':
    unittest.main()
