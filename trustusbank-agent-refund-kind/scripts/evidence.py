"""Build evidence only from emitted gateway access-log attributes."""
import json
import re
import sys
import os
from pathlib import Path

legal_reference = {
    'verified': '21 Oct 2026',
    'regulation': 'DORA, Regulation (EU) 2022/2554, Article 9 (OJ L 333/1, 27.12.2022)',
    'source': 'https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:32022R2554',
    'quotes': {
        '9(4)(b)': 'following a risk-based approach, establish a sound network and infrastructure management structure using appropriate techniques, methods and protocols that may include implementing automated mechanisms to isolate affected information assets in the event of cyber-attacks',
        '9(4) second subparagraph': 'For the purposes of the first subparagraph, point (b), financial entities shall design the network connection infrastructure in a way that allows it to be instantaneously severed or segmented in order to minimise and prevent contagion, especially for interconnected financial processes.',
        '9(4)(c)': 'implement policies that limit the physical or logical access to information assets and ICT assets to what is required for legitimate and approved functions and activities only, and establish to that end a set of policies, procedures and controls that address access rights and ensure a sound administration thereof',
        '9(4)(d)': 'implement policies and protocols for strong authentication mechanisms, based on relevant standards and dedicated control systems, and protection measures of cryptographic keys whereby data is encrypted based on results of approved data classification and ICT risk assessment processes',
    },
}
control_mapping = {
    'step 6 instance switch': 'relevant to DORA 9(4)(b) and 9(4) second subparagraph',
    'steps 2, 3 and 5 access controls': 'relevant to DORA 9(4)(c)',
    'steps 1 and 3 authentication and keys': 'relevant to DORA 9(4)(d)',
}

records = []
for line in sys.stdin:
    if 'audit.chain=' not in line or 'mcp.method.name=tools/call' not in line:
        continue
    fields = {}
    for match in re.finditer(r'([\w.]+)=("(?:\\.|[^"\\])*"|\S+)', line):
        key, value = match.groups()
        if value.startswith('"'):
            value = json.loads(value)
        fields[key] = value
    if 'audit.chain' in fields:
        fields['audit.chain'] = json.loads(fields['audit.chain'])
    records.append({'timestamp': line.split()[0], 'attributes': fields,
                    'source': 'bank/bank-gw access log',
                    'control_mapping': control_mapping})
assert records, 'No real tool-call audit attributes found'
pack = {'legal_reference': legal_reference, 'calls': records}
approval_path = os.environ.get('BANK_APPROVAL_EVIDENCE')
if approval_path:
    approval = json.loads(Path(approval_path).read_text())
    linked = [r for r in records if r['attributes'].get('audit.call') == approval['context_id']
              and r['attributes'].get('gen_ai.tool.name') == 'refund_payment'
              and r['attributes'].get('audit.sub') == approval['human_sub']]
    assert linked, 'No gateway refund call matches the native approval context and human subject'
    pack['calls'] = linked
    pack['approval'] = approval
print(json.dumps(pack, indent=2))
