#!/usr/bin/env python3
"""Exercise Desktop-shaped requests through the live intake gateway, using bob's token."""
import argparse
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request

TELCO = 'How does a 5G network slice guarantee latency for an enterprise customer?'
GENERIC = 'Explain what a Python list comprehension is'


def request_body(content, **extra):
    return {'model': 'claude-sonnet-5', 'max_tokens': 32, 'stream': True,
            'messages': [{'role': 'user', 'content': content}], **extra}


def cases():
    reminder = '<system-reminder>' + (
        'Repository instructions: review code, modify functions, fix bugs, add a test.\n' * 200
    ) + '</system-reminder>\n'
    yield 'plain telco question', '/v1/messages', request_body(TELCO), 200, 'telco', 'mistral-small-3.2-24b'
    yield 'Claude reminders, string content', '/v1/messages', request_body(reminder + TELCO), 200, 'telco', 'mistral-small-3.2-24b'
    yield 'Claude reminders, content parts', '/v1/messages', request_body([
        {'type': 'text', 'text': reminder}, {'type': 'text', 'text': TELCO}
    ]), 200, 'telco', 'mistral-small-3.2-24b'
    yield 'question between reminders', '/v1/messages', request_body(
        reminder + TELCO + '\n<system-reminder>Review the repository rules.</system-reminder>'
    ), 200, 'telco', 'mistral-small-3.2-24b'

    tools = [{'type': 'function', 'function': {
        'name': 'lookup', 'description': 'Look up network information',
        'parameters': {'type': 'object', 'properties': {}}
    }}]
    messages = [
        {'role': 'system', 'content': 'Answer briefly using the supplied network information.'},
        {'role': 'user', 'content': TELCO},
        {'role': 'assistant', 'content': None, 'tool_calls': [
            {'id': 'call00001', 'type': 'function', 'function': {'name': 'lookup', 'arguments': '{}'}}]},
        {'role': 'tool', 'tool_call_id': 'call00001', 'content': '5G slices use QoS policies and resource allocation.'},
        {'role': 'system', 'content': [{'type': 'text', 'text': 'Answer in one sentence. Do not call another tool.'}]},
    ]
    followup = request_body('', messages=messages, tools=tools)
    yield 'system message after tool result', '/v1/chat/completions', followup, 200, 'telco', 'mistral-small-3.2-24b'
    yield 'internal context still inspected', '/v1/messages', request_body(
        '<system-reminder>Repository: com.example.internal settlement-service</system-reminder>\n' + GENERIC
    ), 200, 'generic_coding', 'qwen3-coder-30b'
    # Deliberately synthetic credential-shaped text. OPA must see it in the retained reminder.
    yield 'credential in reminder still blocked', '/v1/messages', request_body(
        '<system-reminder>Example credential: ' + 'AKIA' + 'A' * 16 + '</system-reminder>\n' + GENERIC
    ), 422, None, None


def run(base, token):
    passed = total = 0
    for name, path, body, expected, task, model in cases():
        total += 1
        req = urllib.request.Request(base.rstrip('/') + path,
            data=json.dumps(body).encode(), headers={
                'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
                'anthropic-version': '2023-06-01',
            })
        try:
            try:
                response = urllib.request.urlopen(req, timeout=180)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                raw = response.read().decode()
                assert response.status == expected, f'HTTP {response.status}, expected {expected}'
                if expected == 200:
                    assert response.headers.get('x-vsr-selected-model') == task, 'wrong task'
                    assert response.headers.get('x-model-pool') == 'private', 'request left the private pool'
                    frames = [json.loads(line[6:]) for line in raw.splitlines()
                              if line.startswith('data: ') and line[6:] != '[DONE]']
                    models = {frame.get('model') or frame.get('message', {}).get('model')
                              for frame in frames}
                    assert model in models, f'expected {model}, got {models}'
                    complete = 'message_stop' in raw if path == '/v1/messages' else '[DONE]' in raw
                    assert complete, 'stream did not finish'
                print(f'PASS {name}: HTTP {response.status}' + (f', {task}, {model}' if task else ''))
                passed += 1
        except (AssertionError, OSError, ValueError) as error:
            print(f'FAIL {name}: {error}', file=sys.stderr)
    print(f'Desktop compatibility: {passed}/{total} passed')
    return passed == total


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', default=os.environ.get('AGW_BASE_URL'), required='AGW_BASE_URL' not in os.environ)
    parser.add_argument('--token-file', type=Path, default=Path.home() / '.config/agw/token')
    args = parser.parse_args()
    sys.exit(0 if run(args.base_url, args.token_file.expanduser().read_text().strip()) else 1)
