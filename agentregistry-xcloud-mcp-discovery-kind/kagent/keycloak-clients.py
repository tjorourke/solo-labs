"""Add the two Solo UI clients to the agentregistry realm and store the backend secret in the cluster.

kagent-backend: confidential, used by the kagent controller and the Solo UI backend.
kagent-ui: public, auth code + PKCE S256, used by the Solo UI in the browser.
All get the Groups mapper (same as the realm's other clients) so the groups claim is in the user token that the
STS exchanges, and an audience mapper for kagent-backend.
Client shape from https://docs.solo.io/kagent/0.5.x/security/idp/keycloak/ Step 2 and the tested
trustusbank-agent-refund-kind/scripts/enterprise-oidc.py. Talks to Keycloak on the lab port-forward 127.0.0.1:8180.
The secret goes to kubectl on stdin and is never printed.
"""
import json
import subprocess
import sys
import urllib.parse
import urllib.request

KC = 'http://127.0.0.1:8180'
CTX = 'kind-xcloud-mcp'
UI = 'http://localhost:19480'


def call(url, data=None, method=None, token=None, form=False):
    body = None
    headers = {}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
        else:
            body = json.dumps(data).encode()
            headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


admin = call(KC + '/realms/master/protocol/openid-connect/token',
             {'client_id': 'admin-cli', 'username': 'admin', 'password': 'admin', 'grant_type': 'password'},
             form=True)['access_token']
mappers = [
    {'name': 'groups', 'protocol': 'openid-connect', 'protocolMapper': 'oidc-group-membership-mapper',
     'config': {'claim.name': 'Groups', 'full.path': 'false', 'id.token.claim': 'true',
                'access.token.claim': 'true', 'userinfo.token.claim': 'true'}},
    {'name': 'kagent-backend-audience', 'protocol': 'openid-connect', 'protocolMapper': 'oidc-audience-mapper',
     'config': {'included.client.audience': 'kagent-backend', 'access.token.claim': 'true',
                'id.token.claim': 'true'}},
    # The STS only issues a delegated token when the user token names the agent in may_act (RFC 8693 4.4).
    # Without it: "delegation not authorized: subject token does not contain may_act claim" (seen 9 Nov 2026).
    # Hardcoded here, so every lab user may delegate to the cloud-ops agent's service account.
    {'name': 'may-act-cloud-ops', 'protocol': 'openid-connect', 'protocolMapper': 'oidc-hardcoded-claim-mapper',
     'config': {'claim.name': 'may_act', 'claim.value': json.dumps({'sub': 'system:serviceaccount:kagent:cloud-ops'}),
                'jsonType.label': 'JSON', 'access.token.claim': 'true', 'id.token.claim': 'false',
                'userinfo.token.claim': 'false'}},
]
clients = [
    {'clientId': 'kagent-backend', 'enabled': True, 'publicClient': False, 'standardFlowEnabled': True,
     'directAccessGrantsEnabled': True, 'serviceAccountsEnabled': True, 'protocol': 'openid-connect',
     'redirectUris': [UI + '/*'], 'protocolMappers': mappers},
    {'clientId': 'kagent-ui', 'enabled': True, 'publicClient': True, 'standardFlowEnabled': True,
     'directAccessGrantsEnabled': False, 'protocol': 'openid-connect',
     'redirectUris': [UI + '/*'], 'webOrigins': [UI],
     'attributes': {'pkce.code.challenge.method': 'S256', 'post.logout.redirect.uris': '+'},
     'protocolMappers': mappers},
]
root = KC + '/admin/realms/agentregistry/clients'
if '--remove' in sys.argv:
    # Used by scripts/down-kagent.sh: delete the two clients and the may_act mapper on ar-cli-password.
    for cid in ('kagent-backend', 'kagent-ui'):
        for c in call(root + '?clientId=' + cid, token=admin):
            call(root + '/' + c['id'], method='DELETE', token=admin)
    cli = call(root + '?clientId=ar-cli-password', token=admin)[0]
    for m in call(root + '/' + cli['id'] + '/protocol-mappers/models', token=admin):
        if m['name'] == 'may-act-cloud-ops':
            call(root + '/' + cli['id'] + '/protocol-mappers/models/' + m['id'], method='DELETE', token=admin)
    print('Keycloak clients kagent-backend and kagent-ui and the may_act mapper removed.')
    raise SystemExit(0)
for c in clients:
    found = call(root + '?clientId=' + c['clientId'], token=admin)
    if found:
        call(root + '/' + found[0]['id'], c, 'PUT', admin)
    else:
        call(root, c, 'POST', admin)
# The lab's password-grant client (scripts/lib.sh mint_token) gets the same may_act mapper for the curl tests.
cli = call(root + '?clientId=ar-cli-password', token=admin)[0]
have = [m['name'] for m in call(root + '/' + cli['id'] + '/protocol-mappers/models', token=admin)]
if mappers[-1]['name'] not in have:
    call(root + '/' + cli['id'] + '/protocol-mappers/models', mappers[-1], 'POST', admin)
backend = call(root + '?clientId=kagent-backend', token=admin)[0]
secret = call(root + '/' + backend['id'] + '/client-secret', token=admin)['value']
for ns in ('kagent', 'agentgateway-system'):
    obj = {'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {'name': 'kagent-backend-oidc', 'namespace': ns},
           'stringData': {'clientSecret': secret}}
    for extra in (['--dry-run=server'], []):
        r = subprocess.run(['kubectl', '--context', CTX, 'apply', '-f', '-'] + extra, input=json.dumps(obj),
                           text=True, capture_output=True)
        if r.returncode:
            raise SystemExit('Secret apply failed in ' + ns)
print('Keycloak clients kagent-backend and kagent-ui are in place. Secret kagent-backend-oidc written.')
