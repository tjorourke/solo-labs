#!/usr/bin/env python3
"""Publish selected test evidence without runtime credentials or machine IDs."""
import json
from pathlib import Path

lab = Path(__file__).resolve().parents[1]
source = lab / '.runtime/results'
target = lab / 'captures'
target.mkdir(exist_ok=True)

def load(name):
    return json.loads((source / (name + '.json')).read_text())

def write(name, obj):
    (target / (name + '.json')).write_text(json.dumps(obj, indent=2) + '\n')

verification = load('verification')
assert verification['passed'], 'Only export a passing run'
for name in ('verification', 'placement', 'negative-controls'):
    write(name, load(name))
for name in ('baseline', 'hardened', 'ownership-restore'):
    data = load(name)
    assert data['passed'], name
    write(name, {k: v for k, v in data.items() if k not in ('workerLogs', 'ateletLogs')})
for name in ('baseline-worker', 'hardened-worker', 'hardened-atelet'):
    data = load(name)
    spec = data['podSpec']
    write(name, {'process': data['process'], 'nodeName': spec.get('nodeName'), 'serviceAccountName': spec.get('serviceAccountName'),
        'automountServiceAccountToken': spec.get('automountServiceAccountToken', True),
        'nodeSelector': spec.get('nodeSelector'), 'hostPaths': [v['hostPath'] for v in spec['volumes'] if 'hostPath' in v],
        'containers': [{'name': c['name'], 'securityContext': c.get('securityContext', {}), 'ports': c.get('ports', [])} for c in spec['containers']]})
env = load('environment')
for node in env['nodes']:
    node['info'] = {k: v for k, v in node['info'].items() if k in ('architecture', 'kernelVersion', 'containerRuntimeVersion', 'kubeletVersion', 'osImage')}
write('environment', env)
write('seccomp-arm64-example', load('seccomp-profile')['modified'])
print('Exported passing lifecycle, kernel, placement and negative-control evidence')
