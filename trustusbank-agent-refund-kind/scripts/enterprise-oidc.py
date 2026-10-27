"""Configure the existing bank realm and pass client credentials through stdin."""
import copy
import json
import subprocess
from pathlib import Path

K = ['kubectl', '--context', 'kind-trustusbank-lab']


def k(*args, data=None):
    result = subprocess.run(K + list(args), input=data, text=True, capture_output=True)
    if result.returncode:
        sensitive = any('Bearer ' in arg for arg in args)
        sensitive = sensitive or (data is not None and '"kind": "Secret"' in data)
        raise RuntimeError('Credential-bearing Kubernetes request failed' if sensitive else result.stderr)
    return result.stdout


def apply(obj):
    body = json.dumps(obj)
    k('apply', '--dry-run=server', '-f', '-', data=body)
    k('apply', '-f', '-', data=body)


def request(url, data=None, method=None):
    args = ['-n', 'bank', 'exec', '-i', 'tools', '--', 'curl', '--fail', '-sS', url]
    if method:
        args += ['-X', method]
    if admin:
        args += ['-H', 'Authorization: Bearer ' + admin]
    if data is not None:
        args += ['-H', 'Content-Type: application/json', '--data-binary', '@-']
    value = k(*args, data=json.dumps(data) if data is not None else None)
    return json.loads(value) if value else None


admin = ''
kc = 'http://keycloak.keycloak.svc.cluster.local:8080'
admin = json.loads(k('-n', 'bank', 'exec', 'tools', '--', 'curl', '--fail', '-sS',
                    kc + '/realms/master/protocol/openid-connect/token',
                    '-d', 'grant_type=password', '-d', 'client_id=admin-cli',
                    '-d', 'username=admin', '-d', 'password=admin'))['access_token']
realm = json.loads((Path(__file__).parents[1] / 'yaml/realm-bank.json').read_text())
realm_root = kc + '/admin/realms/bank'
# Import is only used on the first boot. Reconcile people and mappers on reruns.
profile = request(realm_root + '/users/profile')
if not any(a['name'] == 'bank_may_act_sub' for a in profile['attributes']):
    profile['attributes'].append({'name': 'bank_may_act_sub',
                                  'permissions': {'view': ['admin'], 'edit': ['admin']}})
    request(realm_root + '/users/profile', profile, 'PUT')
for group in realm['groups']:
    if not any(g['name'] == group['name'] for g in request(realm_root + '/groups')):
        request(realm_root + '/groups', group, 'POST')
groups = {g['name']: g['id'] for g in request(realm_root + '/groups')}
for group in realm['groups']:
    # Delegation is inherited from IdP group membership, not a named person.
    request(realm_root + '/groups/' + groups[group['name']], group, 'PUT')
for source in realm['users']:
    user = {key: value for key, value in source.items() if key != 'groups'}
    found = request(realm_root + '/users?exact=true&username=' + user['username'])
    if found:
        uid = found[0]['id']
        request(realm_root + '/users/' + uid, user, 'PUT')
    else:
        request(realm_root + '/users', user, 'POST')
        uid = request(realm_root + '/users?exact=true&username=' + user['username'])[0]['id']
    for group in source['groups']:
        request(realm_root + '/users/' + uid + '/groups/' + groups[group], method='PUT')
mappers = copy.deepcopy(next(c for c in realm['clients'] if c['clientId'] == 'bank-ui')['protocolMappers'])
mappers.append({'name': 'bank-enterprise-audience', 'protocol': 'openid-connect',
                'protocolMapper': 'oidc-audience-mapper',
                'config': {'included.client.audience': 'bank-enterprise',
                           'access.token.claim': 'true', 'id.token.claim': 'true'}})
clients = realm['clients'] + [
    {'clientId': 'bank-enterprise', 'enabled': True, 'publicClient': False,
     'standardFlowEnabled': True, 'serviceAccountsEnabled': True,
     'directAccessGrantsEnabled': True, 'protocol': 'openid-connect',
     'protocolMappers': mappers},
    {'clientId': 'bank-enterprise-ui', 'enabled': True, 'publicClient': True,
     'standardFlowEnabled': True, 'protocol': 'openid-connect',
     'redirectUris': ['http://refund-lab.localhost:19380/*', 'http://refund-lab.localhost:19390/*'],
     'webOrigins': ['http://refund-lab.localhost:19380', 'http://refund-lab.localhost:19390'],
     'attributes': {'pkce.code.challenge.method': 'S256', 'post.logout.redirect.uris': '+'},
     'protocolMappers': mappers},
]
root = kc + '/admin/realms/bank/clients'
for client in clients:
    found = request(root + '?clientId=' + client['clientId'])
    if found:
        request(root + '/' + found[0]['id'], client, 'PUT')
    else:
        request(root, client, 'POST')
backend = request(root + '?clientId=bank-enterprise')[0]
secret = request(root + '/' + backend['id'] + '/client-secret')['value']
for ns in ('kagent', 'agentgateway-system'):
    apply({'apiVersion': 'v1', 'kind': 'Secret',
           'metadata': {'name': 'bank-enterprise-oidc', 'namespace': ns},
           'stringData': {'clientSecret': secret}})
svc = json.loads(k('-n', 'keycloak', 'get', 'service', 'keycloak', '-o', 'json'))
ports = svc['spec']['ports']
ports[0]['name'] = 'http'
if not any(p['port'] == 19580 for p in ports):
    ports.append({'name': 'issuer', 'port': 19580, 'targetPort': 8080})
patch = json.dumps({'spec': {'ports': ports}})
k('-n', 'keycloak', 'patch', 'service', 'keycloak', '--type=merge', '-p', patch, '--dry-run=server')
k('-n', 'keycloak', 'patch', 'service', 'keycloak', '--type=merge', '-p', patch)
dns = json.loads(k('-n', 'kube-system', 'get', 'configmap', 'coredns', '-o', 'json'))
core = dns['data']['Corefile']
rewrite = 'rewrite name refund-idp.localtest.me keycloak.keycloak.svc.cluster.local'
if rewrite not in core:
    dns['data']['Corefile'] = core.replace('ready', 'ready\n    ' + rewrite, 1)
    dns.pop('status', None)
    for key in ('resourceVersion', 'uid', 'creationTimestamp', 'managedFields'):
        dns['metadata'].pop(key, None)
    apply(dns)
    # Do not let the first OIDC discovery race CoreDNS's ConfigMap reload and
    # cache the public localhost answer for keycloak.localtest.me.
    k('-n', 'kube-system', 'rollout', 'restart', 'deployment/coredns')
    k('-n', 'kube-system', 'rollout', 'status', 'deployment/coredns', '--timeout=120s')
print('Enterprise OIDC configured: Carol, Bob, Sarah and Alice; group-derived delegation grants.')
