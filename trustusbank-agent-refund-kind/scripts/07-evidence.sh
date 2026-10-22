#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
approval=/tmp/trustusbank-native-approval.json
ui_approval=$(mktemp)
if k -n bank exec deploy/orchestrator -- python -c 'from pathlib import Path; print(Path("/tmp/trustusbank-ui-approval.json").read_text())' > "$ui_approval" 2>/dev/null; then
  cp "$ui_approval" /tmp/trustusbank-ui-approval.json
  approval=/tmp/trustusbank-ui-approval.json
fi
rm -f "$ui_approval"
if [[ ! -f "$approval" ]]; then
  printf 'Approve a refund in Bob\047s kagent chat before pulling the evidence.\n' >&2
  exit 1
fi
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
k -n bank logs deploy/bank-gw --since=30m | BANK_APPROVAL_EVIDENCE="$approval" python3 "$LAB/scripts/evidence.py" > "$tmp"
cp "$tmp" /tmp/trustusbank-evidence.json
python3 - "$tmp" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
a=p['approval']; c=p['calls'][-1]['attributes']
assert c['audit.actor']=='system:serviceaccount:bank:ledger-agent'
print('Evidence record:')
print('Requested by:',a['human'])
print('Assistant:',c['audit.chain']['act']['sub'].split(':')[-1])
print('Refunds agent:',c['audit.actor'].split(':')[-1])
print('Approved by:',a['human'])
print('Payment:',a['arguments']['payment_id'])
print('Amount GBP:',a['arguments']['amount_gbp'])
print('Refund:',a['result']['refund'])
print('Gateway call matches approval context:',c['audit.call']==a['context_id'])
print('Full JSON: /tmp/trustusbank-evidence.json')
PY
printf 'Saved evidence: /tmp/trustusbank-evidence.json\n'
