#!/usr/bin/env python3
"""Executable walkthrough. All cluster operations use an isolated kubeconfig."""
import contextlib
import copy
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

LAB = Path(__file__).resolve().parents[1]
STATE = LAB / '.runtime'
RESULTS = STATE / 'results'
SOURCE = STATE / 'substrate'
CLUSTER = 'substrate-least-privilege'
REGISTRY = CLUSTER + '-registry'
REPO = 'localhost:5507'
NS = 'substrate-lab'
POOL = 'least-privilege'
RELEASE = 'substrate-policy'
VERSION = 'v0.4.0'
COMMIT = '756c2a53741121e728f4cc3066c8a19e575b4919'
K = ['kubectl', '--kubeconfig', str(STATE / 'kubeconfig')]
A = [str(STATE / 'kubectl-ate'), '--kubeconfig', str(STATE / 'kubeconfig')]
H = ['helm', '--kubeconfig', str(STATE / 'kubeconfig')]
DEFAULT_CAPS = ['NET_ADMIN', 'SYS_ADMIN', 'SYS_CHROOT', 'SYS_PTRACE', 'SETUID', 'SETGID', 'SETPCAP', 'DAC_OVERRIDE', 'FOWNER', 'CHOWN', 'MKNOD', 'NET_RAW', 'SETFCAP']
REDUCED_CAPS = ['NET_ADMIN', 'SYS_ADMIN', 'SETUID', 'SETGID', 'DAC_OVERRIDE', 'NET_RAW', 'SETFCAP', 'CHOWN', 'FOWNER']

def run(args, *, data=None, cwd=None, env=None, timeout=120, check=True, stream=False):
    args = [str(x) for x in args]
    p = subprocess.run(args, input=json.dumps(data) if data is not None else None,
                       cwd=cwd, env=env, text=True, capture_output=not stream, timeout=timeout)
    if check and p.returncode:
        raise RuntimeError('Command failed: ' + ' '.join(args) + '\n' + (p.stdout or '') + (p.stderr or ''))
    return p

def k(*args, **kwargs):
    return run(K + list(args), **kwargs)

def ate(*args, **kwargs):
    return run(A + list(args), **kwargs)

def get(*args):
    return json.loads(k(*args, '-o', 'json').stdout)

def save(name, obj):
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / name).write_text(json.dumps(obj, indent=2) + '\n')

def wait_for(fn, *, seconds=120, message='condition'):
    end = time.monotonic() + seconds
    last = None
    while time.monotonic() < end:
        try:
            last = fn()
            if last:
                return last
        except (RuntimeError, KeyError, IndexError) as e:
            last = str(e)
        time.sleep(1)
    raise RuntimeError(f'Timed out waiting for {message}: {last}')

def apply(doc):
    k('apply', '-f', '-', data=doc)

def worker_pods():
    return [p for p in get('-n', NS, 'get', 'pods', '-l', 'ate.dev/worker-pool=' + POOL)['items']
            if not p['metadata'].get('deletionTimestamp')]

def ready_worker():
    pods = worker_pods()
    return pods[0] if len(pods) == 1 and any(c['type'] == 'Ready' and c['status'] == 'True'
         for c in pods[0].get('status', {}).get('conditions', [])) else None

def replace_worker():
    old = {p['metadata']['uid'] for p in worker_pods()}
    k('-n', NS, 'delete', 'pods', '-l', 'ate.dev/worker-pool=' + POOL, '--wait=false')
    pod = wait_for(lambda: (p if (p := ready_worker()) and p['metadata']['uid'] not in old else None),
                   message='replacement worker')
    def registered():
        workers = json.loads(ate('get', 'workers', '-o', 'json').stdout).get('workers', [])
        return any(w.get('workerPodUid') == pod['metadata']['uid'] and
                   w.get('status', {}).get('state') == 'WORKER_STATE_ACTIVE' for w in workers)
    wait_for(registered, message='replacement worker registered in Substrate')
    return pod

def inspection(pod, container=0):
    cid = pod['status']['containerStatuses'][container]['containerID'].split('://')[1]
    node = pod['spec']['nodeName']
    info = json.loads(run(['docker', 'exec', node, 'crictl', 'inspect', cid]).stdout)['info']
    status = run(['docker', 'exec', node, 'cat', f"/proc/{info['pid']}/status"]).stdout
    fields = {line.split(':', 1)[0]: line.split(':', 1)[1].strip() for line in status.splitlines() if ':' in line}
    return {'runtimeSpec': info['runtimeSpec'], 'process': {x: fields[x] for x in ('Uid', 'Gid', 'CapEff', 'CapBnd', 'NoNewPrivs', 'Seccomp')}}

def helm(hardened, extra=None):
    image = (STATE / 'worker-image').read_text().strip()
    cmd = H + ['upgrade', '--install', RELEASE, str(LAB / 'charts/runtime-policy'), '-n', NS, '--create-namespace',
               '--set-string', 'worker.image=' + image, '--wait', '--timeout', '2m']
    if hardened:
        cmd += ['-f', str(LAB / 'yaml/hardened-values.yaml')]
    if extra:
        cmd += extra
    run(cmd)
    if hardened:
        values = json.loads(run(H + ['get', 'values', RELEASE, '-n', NS, '--all', '-o', 'json']).stdout)
        expected = values['worker']['securityContext']
        def policy_ready():
            probe = {'apiVersion': 'v1', 'kind': 'Pod', 'metadata': {'name': 'admission-probe', 'namespace': NS, 'labels': {'ate.dev/worker-pool': POOL}},
                     'spec': {'containers': [{'name': 'ateom', 'image': 'busybox:1.36'}]}}
            live = json.loads(k('create', '--dry-run=server', '-f', '-', '-o', 'json', data=probe).stdout)
            return live['spec']['containers'][0].get('securityContext') == expected
        wait_for(policy_ready, message='exact Helm security settings active at admission')

def prepare():
    for tool in ('docker', 'kind', 'kubectl', 'helm', 'git', 'go'):
        if not shutil.which(tool):
            raise RuntimeError('Install required tool: ' + tool)
    for directory in ('seccomp', 'results', 'docker-public', 'fixture'):
        (STATE / directory).mkdir(parents=True, exist_ok=True)
    # Only public base-image pulls use this isolated config. Do not alter login state.
    (STATE / 'docker-public/config.json').write_text('{"auths":{}}\n')
    clusters = run(['kind', 'get', 'clusters']).stdout.splitlines()
    if CLUSTER not in clusters:
        cfg = (LAB / 'yaml/kind.yaml').read_text().replace('${SECCOMP_DIR}', str(STATE / 'seccomp'))
        (STATE / 'kind.yaml').write_text(cfg)
        run(['kind', 'create', 'cluster', '--name', CLUSTER, '--config', STATE / 'kind.yaml', '--kubeconfig', STATE / 'kubeconfig'], timeout=300, stream=True)
        (STATE / 'owned-cluster').write_text(CLUSTER)
    elif not (STATE / 'owned-cluster').exists():
        raise RuntimeError('Cluster name is already in use by another run; refusing to adopt it')
    exists = run(['docker', 'inspect', REGISTRY], check=False)
    if exists.returncode:
        run(['docker', 'run', '-d', '--name', REGISTRY, '--label', 'lab=substrate-least-privilege',
             '--network', 'kind', '-p', '127.0.0.1:5507:5000', 'registry:2'], stream=True)
    else:
        assert json.loads(exists.stdout)[0]['Config']['Labels'].get('lab') == CLUSTER, 'Registry is not owned by this lab'
    hosts = STATE / 'hosts.toml'
    hosts.write_text(f'[host."http://{REGISTRY}:5000"]\n  capabilities = ["pull", "resolve"]\n')
    for node in run(['kind', 'get', 'nodes', '--name', CLUSTER]).stdout.splitlines():
        run(['docker', 'exec', node, 'mkdir', '-p', '/etc/containerd/certs.d/localhost:5507'])
        run(['docker', 'cp', hosts, node + ':/etc/containerd/certs.d/localhost:5507/hosts.toml'])
        run(['docker', 'exec', node, 'sysctl', 'net.ipv4.conf.all.proxy_arp=1'])
    k('taint', 'node', CLUSTER + '-worker', 'ate.dev/sandboxClass=gvisor:NoSchedule', '--overwrite')
    if not SOURCE.exists():
        run(['git', 'clone', '--depth', '1', '--branch', VERSION, 'https://github.com/agent-substrate/substrate.git', SOURCE], timeout=180, stream=True)
    assert run(['git', 'rev-parse', 'HEAD'], cwd=SOURCE).stdout.strip() == COMMIT, 'Unexpected upstream commit'
    for binary, package in [('ate-setup', './cmd/ate-setup'), ('kubectl-ate', './cmd/kubectl-ate')]:
        run(['go', 'build', '-o', STATE / binary, package], cwd=SOURCE, timeout=600, stream=True)
    print('PASS: isolated cluster, dedicated runtime node and pinned tools', flush=True)

def build_env():
    return dict(os.environ, DOCKER_CONFIG=str(STATE / 'docker-public'), KO_DOCKER_REPO=REPO,
                KO_DEFAULTPLATFORMS='linux/' + run(['go', 'env', 'GOARCH']).stdout.strip())

def build_probe(layer_id):
    env = dict(os.environ, GOOS='linux', GOARCH=run(['go', 'env', 'GOARCH']).stdout.strip(), CGO_ENABLED='0')
    run(['go', 'build', '-o', STATE / 'fixture/probe', LAB / 'probe/main.go'], env=env, timeout=180)
    shutil.copyfile(LAB / 'probe/Dockerfile', STATE / 'fixture/Dockerfile')
    run(['docker', 'buildx', 'build', '--builder', 'default', '--load', '--build-arg', 'PROBE_LAYER_ID=' + layer_id,
         '-t', REPO + '/privilege-probe:v1', STATE / 'fixture'], timeout=180, stream=True)
    run(['docker', 'push', REPO + '/privilege-probe:v1'], timeout=180, stream=True)
    digest = json.loads(run(['docker', 'image', 'inspect', REPO + '/privilege-probe:v1']).stdout)[0]['RepoDigests'][0]
    (STATE / 'probe-image').write_text(digest + '\n')
    return digest

def install():
    run([STATE / 'ate-setup', 'deploy', 'ate-system', '--kind', '--kind-cluster-name', CLUSTER,
         '--kubeconfig', STATE / 'kubeconfig', '--no-dev-env', '--ko-docker-repo', REPO,
         '--credential-provider', '{"enabled":false}', '--atenet-dataplane', 'agentgateway',
         '--rollout-timeout', '5m', '--no-report-defaults'], cwd=SOURCE, env=build_env(), timeout=1200, stream=True)
    ds = get('-n', 'ate-system', 'get', 'ds', 'atelet-v0-4-0')
    save('atelet-upstream-podspec.json', ds['spec']['template']['spec'])
    args = ds['spec']['template']['spec']['containers'][0]['args']
    args = [f'--localhost-registry-replacement={REGISTRY}:5000' if x.startswith('--localhost-registry-replacement=') else x for x in args]
    k('-n', 'ate-system', 'patch', 'ds', 'atelet-v0-4-0', '--type=json', '-p', json.dumps([
        {'op': 'replace', 'path': '/spec/template/spec/containers/0/args', 'value': args}]))
    k('-n', 'ate-system', 'rollout', 'status', 'ds/atelet-v0-4-0', '--timeout=180s', timeout=200)
    ko = run(['go', 'tool', '-n', 'ko'], cwd=SOURCE / 'hack/tools/ko').stdout.strip()
    p = run([ko, 'build', './cmd/ateom-gvisor', '--base-import-paths', '--ldflags=-X=github.com/agent-substrate/substrate/internal/version.Version=' + VERSION],
            cwd=SOURCE, env=build_env(), timeout=600)
    print(p.stderr, flush=True)
    (STATE / 'worker-image').write_text(p.stdout.strip().splitlines()[-1] + '\n')
    digest = build_probe('baseline')
    helm(False)
    wait_for(ready_worker, message='baseline worker')
    # Atespaces are Substrate API resources, not Kubernetes namespaces.
    if ate('get', 'atespace', NS, check=False).returncode:
        ate('create', 'atespace', NS)
    echo = {'apiVersion': 'apps/v1', 'kind': 'Deployment', 'metadata': {'name': 'echo', 'namespace': NS},
            'spec': {'replicas': 1, 'selector': {'matchLabels': {'app': 'privilege-echo'}}, 'template': {
                'metadata': {'labels': {'app': 'privilege-echo'}}, 'spec': {
                    'nodeSelector': {'lab.mastertheagent.com/pool': 'general'}, 'automountServiceAccountToken': False,
                    'containers': [{'name': 'echo', 'image': digest, 'env': [{'name': 'PROBE_ROLE', 'value': 'echo'}, {'name': 'PORT', 'value': '8080'}],
                        'securityContext': {'runAsUser': 65532, 'runAsNonRoot': True, 'allowPrivilegeEscalation': False, 'readOnlyRootFilesystem': True,
                                            'capabilities': {'drop': ['ALL']}, 'seccompProfile': {'type': 'RuntimeDefault'}}}]}}}}
    apply(echo)
    apply({'apiVersion': 'v1', 'kind': 'Service', 'metadata': {'name': 'echo', 'namespace': NS},
           'spec': {'selector': {'app': 'privilege-echo'}, 'ports': [{'port': 8080, 'targetPort': 8080}]}})
    k('-n', NS, 'rollout', 'status', 'deployment/echo', '--timeout=120s', timeout=130)
    save('environment.json', {'date': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'substrate': VERSION,
         'commit': COMMIT, 'nodes': [{'name': n['metadata']['name'], 'info': n['status']['nodeInfo']} for n in get('get', 'nodes')['items']],
         'workerImage': (STATE / 'worker-image').read_text().strip(), 'probeImage': digest,
         'sandboxConfig': get('get', 'sandboxconfig', 'gvisor-default')['spec']})
    print('PASS: upstream runtime, baseline WorkerPool and general-node echo service', flush=True)

@contextlib.contextmanager
def router():
    log = (STATE / 'port-forward.log').open('w')
    process = subprocess.Popen(K + ['-n', 'ate-system', 'port-forward', 'svc/atenet-router', '18981:80'], stdout=log, stderr=log)
    try:
        import socket
        def listening():
            if process.poll() is not None: raise RuntimeError('Port-forward exited; see .runtime/port-forward.log')
            try:
                with socket.create_connection(('127.0.0.1', 18981), timeout=1): return True
            except OSError: return False
        wait_for(listening, seconds=15, message='router port-forward')
        yield
    finally:
        process.terminate()
        process.wait(timeout=10)
        log.close()

def request(actor, path='/'):
    req = urllib.request.Request('http://127.0.0.1:18981' + path, headers={'ate-target-actor': NS + '/' + actor})
    try:
        with urllib.request.urlopen(req, timeout=40) as resp: return resp.read().decode()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f'Actor HTTP {e.code}: {e.read().decode()}') from e

def template(name, *, baseline=False, ownership=False):
    t = json.loads((LAB / 'yaml/actor-template.json').read_text().replace('${PROBE_IMAGE}', (STATE / 'probe-image').read_text().strip()))
    t['metadata']['name'] = name
    if baseline: t['containers'][0].pop('securityContext')
    if ownership:
        t['containers'][0]['securityContext']['capabilities']['add'] = ['CHOWN']
        t['containers'][0]['env'].append({'name': 'OWNERSHIP_PROBE', 'value': 'true'})
    return t

def lifecycle(label, *, baseline=False, ownership=False, replacement=False):
    name = label.replace('_', '-') + '-' + str(time.time_ns())[-9:]
    result = {'case': label, 'actorTemplate': template(name, baseline=baseline, ownership=ownership)}
    try:
        ate('create', 'actor-template', '-f', '-', data=result['actorTemplate'])
        def golden():
            t = json.loads(ate('get', 'actor-template', name, '-a', NS, '-o', 'json').stdout)
            result['templateStatus'] = t.get('status', {})
            return t.get('status', {}).get('goldenSnapshotStatus', {}).get('goldenTag')
        wait_for(golden, seconds=45, message='fresh golden snapshot')
        ate('create', 'actor', name, '-a', NS, '--template', name)
        ate('create', 'egress-policy', name, '-a', NS, '-f', LAB / 'yaml/egress-policy.json')
        with router():
            for number in (1, 2):
                result[f'turn{number}'] = json.loads(request(name))
                assert result[f'turn{number}'] == {'memory': number, 'file': number}, result
                result[f'actorStatus{number}'] = json.loads(request(name, '/status'))
                mask = int(result[f'actorStatus{number}']['CapEff'], 16)
                assert mask == (0x20000420 if baseline else 1 if ownership else 0), result
                for field in ('CapPrm', 'CapBnd'):
                    assert int(result[f'actorStatus{number}'][field], 16) == mask
                for field in ('CapInh', 'CapAmb'):
                    assert int(result[f'actorStatus{number}'][field], 16) == 0
                if ownership:
                    result[f'ownership{number}'] = json.loads(request(name, '/ownership'))
                    assert result[f'ownership{number}'] == {'uid': 1000, 'gid': 1000, 'mode': '0644', 'content': 'uid-1000'}
                result[f'egress{number}'] = request(name, '/egress')
                assert result[f'egress{number}'] == 'echo-from-general', result
                ate('suspend', 'actor', name, '-a', NS)
            if replacement:
                old_uid = ready_worker()['metadata']['uid']
                fresh = replace_worker()
                assert fresh['metadata']['uid'] != old_uid
                assert fresh['spec']['nodeName'] == CLUSTER + '-worker'
                assert fresh['spec'].get('automountServiceAccountToken') is False
                assert set(fresh['spec']['containers'][0]['securityContext']['capabilities']['add']) == set(REDUCED_CAPS)
                result['replacementPod'] = fresh['metadata']['name']
                def resumed():
                    p = ate('resume', 'actor', name, '-a', NS, check=False)
                    if p.returncode and 'ResourceExhausted' not in p.stderr:
                        raise RuntimeError(p.stderr)
                    return p.returncode == 0
                wait_for(resumed, seconds=90, message='replacement worker visible to the actor scheduler')
                # Probe a read-only endpoint while the router drops its old worker route.
                wait_for(lambda: request(name, '/readyz') == 'ready', seconds=90, message='restored actor route after worker replacement')
                result['turn3'] = json.loads(request(name))
                assert result['turn3'] == {'memory': 3, 'file': 3}, result
                ate('suspend', 'actor', name, '-a', NS)
        result['passed'] = True
    except Exception as e:
        result['passed'] = False
        result['error'] = str(e)
        result['workerLogs'] = k('-n', NS, 'logs', '-l', 'ate.dev/worker-pool=' + POOL, '--tail=100', '--prefix', check=False).stdout.splitlines()
        result['ateletLogs'] = k('-n', 'ate-system', 'logs', 'ds/atelet-v0-4-0', '--tail=100', check=False).stdout.splitlines()
        raise
    finally:
        save(label + '.json', result)
        # A running actor cannot be deleted. Never delete its template first.
        ate('suspend', 'actor', name, '-a', NS, check=False)
        ate('delete', 'actor', name, '-a', NS, check=False)
        ate('delete', 'actor-template', name, '-a', NS, check=False)
    print('PASS: ' + label + ' cold start, state restore, actor capabilities and egress', flush=True)

def baseline():
    pod = wait_for(ready_worker)
    assert set(pod['spec']['containers'][0]['securityContext']['capabilities']['add']) == set(DEFAULT_CAPS), 'Baseline has already been hardened'
    save('baseline-worker.json', {'podSpec': pod['spec'], **inspection(pod)})
    lifecycle('baseline', baseline=True)

def profile():
    probe = {'apiVersion': 'v1', 'kind': 'Pod', 'metadata': {'name': 'seccomp-capture', 'namespace': NS},
        'spec': {'nodeSelector': {'lab.mastertheagent.com/pool': 'runtime'}, 'automountServiceAccountToken': False,
            'tolerations': [{'key': 'ate.dev/sandboxClass', 'operator': 'Equal', 'value': 'gvisor', 'effect': 'NoSchedule'}],
            'containers': [{'name': 'capture', 'image': 'busybox:1.36', 'command': ['sleep', '300'],
                'securityContext': {'runAsUser': 0, 'capabilities': {'drop': ['ALL'], 'add': DEFAULT_CAPS}, 'seccompProfile': {'type': 'RuntimeDefault'}}}]}}
    apply(probe)
    try:
        k('-n', NS, 'wait', 'pod/seccomp-capture', '--for=condition=Ready', '--timeout=120s', timeout=130)
        live = inspection(get('-n', NS, 'get', 'pod', 'seccomp-capture'))
        seccomp = live['runtimeSpec']['linux']['seccomp']
        assert seccomp['defaultAction'] == 'SCMP_ACT_ERRNO', 'Expected a deny-by-default runtime profile'
        original = copy.deepcopy(seccomp)
        assert not any('pivot_root' in s['names'] and s['action'] == 'SCMP_ACT_ALLOW' for s in seccomp['syscalls']), 'Default already permits pivot_root; review before changing it'
        seccomp['syscalls'].append({'names': ['pivot_root'], 'action': 'SCMP_ACT_ALLOW'})
        (STATE / 'seccomp/substrate-worker.json').write_text(json.dumps(seccomp, indent=2) + '\n')
        save('seccomp-profile.json', {'original': original, 'modified': seccomp, 'addedSyscalls': ['pivot_root']})
    finally:
        k('-n', NS, 'delete', 'pod/seccomp-capture', '--ignore-not-found', '--wait=false')
    print('PASS: captured this runtime\'s seccomp profile and allowed only pivot_root additionally', flush=True)

def harden():
    assert (STATE / 'seccomp/substrate-worker.json').exists(), 'Run profile first'
    helm(True)
    # Wait for CEL policy admission to be active before replacing real workers.
    def admitted():
        pod = {'apiVersion': 'v1', 'kind': 'Pod', 'metadata': {'name': 'admission-probe', 'namespace': NS, 'labels': {'ate.dev/worker-pool': POOL}},
               'spec': {'containers': [{'name': 'ateom', 'image': 'busybox:1.36'}]}}
        live = json.loads(k('create', '--dry-run=server', '-f', '-', '-o', 'json', data=pod).stdout)
        return live['spec']['containers'][0].get('securityContext', {}).get('seccompProfile', {}).get('type') == 'Localhost'
    wait_for(admitted, message='worker admission policy')
    k('-n', 'ate-system', 'patch', 'ds', 'atelet-v0-4-0', '--type=strategic', '--patch-file', LAB / 'yaml/atelet-hardened-patch.yaml')
    k('-n', 'ate-system', 'rollout', 'status', 'ds/atelet-v0-4-0', '--timeout=180s', timeout=200)
    replace_worker()
    # A different whiteout layer must be finalised under the reduced capabilities,
    # rather than benefiting from baseline worker cache preparation.
    build_probe('hardened-' + str(time.time_ns()))
    print('PASS: Helm-managed worker admission and dedicated-node atelet overlay', flush=True)

def verify():
    pod = wait_for(ready_worker)
    sc = pod['spec']['containers'][0]['securityContext']
    assert set(sc['capabilities']['add']) == set(REDUCED_CAPS)
    assert sc['privileged'] is False and sc['allowPrivilegeEscalation'] is False
    assert pod['spec'].get('automountServiceAccountToken') is False
    assert not any(v['name'].startswith('kube-api-access') for v in pod['spec']['volumes'])
    assert pod['spec']['nodeName'] == CLUSTER + '-worker'
    live = inspection(pod)
    assert live['process']['NoNewPrivs'] == '1' and live['process']['Seccomp'] == '2'
    assert int(live['process']['CapEff'], 16) == 0x802030cb
    save('hardened-worker.json', {'podSpec': pod['spec'], **live})
    ds = get('-n', 'ate-system', 'get', 'ds', 'atelet-v0-4-0')
    assert ds['status']['desiredNumberScheduled'] == ds['status']['numberReady'] == 1
    daemon = get('-n', 'ate-system', 'get', 'pods', '-l', 'app=atelet')['items']
    daemon = [p for p in daemon if not p['metadata'].get('deletionTimestamp')]
    assert len(daemon) == 1 and daemon[0]['spec']['nodeName'] == CLUSTER + '-worker'
    assert [v['hostPath']['path'] for v in daemon[0]['spec']['volumes'] if 'hostPath' in v] == ['/var/lib/ate']
    assert daemon[0]['spec']['containers'][0]['securityContext']['capabilities']['add'] == ['DAC_OVERRIDE']
    assert daemon[0]['spec']['containers'][0]['securityContext']['readOnlyRootFilesystem']
    save('hardened-atelet.json', {'podSpec': daemon[0]['spec'], **inspection(daemon[0])})
    for who in ('system:serviceaccount:' + NS + ':substrate-worker', 'system:serviceaccount:ate-system:atelet'):
        assert k('auth', 'can-i', 'get', 'secrets', '-A', '--as=' + who, check=False).stdout.strip() == 'no'
    for p in (pod, daemon[0]):
        assert not any(p['spec'].get(x, False) for x in ('hostNetwork', 'hostPID', 'hostIPC'))
    save('placement.json', {'runtime': pod['spec']['nodeName'], 'atelet': daemon[0]['spec']['nodeName'],
        'echo': get('-n', NS, 'get', 'pods', '-l', 'app=privilege-echo')['items'][0]['spec']['nodeName'],
        'desiredAtelets': ds['status']['desiredNumberScheduled'], 'workerTokenMounted': False})
    lifecycle('hardened', replacement=True)
    lifecycle('ownership-restore', ownership=True)
    save('verification.json', {'passed': True, 'date': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'checks': ['dedicated worker placement', 'one atelet on runtime node', 'single daemon hostPath', 'no worker API token',
                   'nine effective worker capabilities', 'NoNewPrivs and seccomp active', 'no host namespaces', 'Secret RBAC denied',
                   'cold start and golden snapshot', 'memory and file state restored', 'actor drop ALL', 'HTTP egress',
                   'worker replacement retains policy and actor state', 'foreign-UID files restored']})
    print('PASS: all placement, kernel, RBAC and lifecycle checks', flush=True)

def negative():
    outcomes = []
    try:
        # This is a real scheduler check: an absent label must not fall back to another node.
        helm(True, ['--set-json', 'worker.nodeSelector=' + json.dumps({'ate.dev/substrate-version': VERSION, 'lab.mastertheagent.com/pool': 'absent'})])
        def pending():
            return next((p for p in worker_pods() if p['spec']['nodeSelector'].get('lab.mastertheagent.com/pool') == 'absent'
                and any(c.get('reason') == 'Unschedulable' for c in p.get('status', {}).get('conditions', []))), None)
        blocked = wait_for(pending, seconds=60, message='missing selector leaves Pod Pending')
        outcomes.append({'case': 'absent-node-label', 'expectedFailure': True, 'conditions': blocked['status']['conditions']})
    finally:
        helm(True)
    wait_for(ready_worker, message='worker after restoring node selector')
    for cap in ('NET_ADMIN', 'CHOWN', 'FOWNER'):
        try:
            caps = [c for c in REDUCED_CAPS if c != cap]
            helm(True, ['--set-json', 'worker.securityContext.capabilities.add=' + json.dumps(caps)])
            replace_worker()
            # Read back the actual Pod so policy-propagation lag cannot fake a result.
            wait_for(lambda: cap not in ready_worker()['spec']['containers'][0]['securityContext']['capabilities']['add'], message='reduced Pod capability list')
            try:
                lifecycle('negative-' + cap.lower(), ownership=cap in ('CHOWN', 'FOWNER'))
            except (RuntimeError, AssertionError) as e:
                evidence = json.loads((RESULTS / ('negative-' + cap.lower() + '.json')).read_text())
                marker = {'NET_ADMIN': 'creating the veth pair', 'CHOWN': 'restoring ownership', 'FOWNER': 'restoring mode'}[cap]
                matches = [line for line in evidence.get('workerLogs', []) if marker in line and 'permitted' in line]
                assert matches, 'Failure did not prove the expected capability dependency: ' + str(e)
                outcomes.append({'case': 'drop-' + cap, 'expectedFailure': True, 'error': str(e), 'evidence': matches})
            else:
                raise AssertionError('Expected failure did not occur without ' + cap)
        finally:
            helm(True)
            replace_worker()
    save('negative-controls.json', outcomes)
    verify()
    print('PASS: negative controls failed as expected and the working profile was restored', flush=True)

def review():
    # Preserve this actor for interactive inspection rather than deleting it like a test.
    if ate('get', 'actor-template', 'review', '-a', NS, check=False).returncode:
        ate('create', 'actor-template', '-f', '-', data=template('review'))
    wait_for(lambda: json.loads(ate('get', 'actor-template', 'review', '-a', NS, '-o', 'json').stdout)
             .get('status', {}).get('goldenSnapshotStatus', {}).get('goldenTag'), message='review golden snapshot')
    if ate('get', 'actor', 'review', '-a', NS, check=False).returncode:
        ate('create', 'actor', 'review', '-a', NS, '--template', 'review')
    if ate('get', 'egress-policy', 'review', '-a', NS, check=False).returncode:
        ate('create', 'egress-policy', 'review', '-a', NS, '-f', LAB / 'yaml/egress-policy.json')
    print('Review actor ready. It stays in the cluster until you remove it.\n'
          'From this lab directory:\n'
          '  export KUBECONFIG="$PWD/.runtime/kubeconfig"\n'
          '  kubectl -n ate-system port-forward svc/atenet-router 18981:80\n'
          'In another terminal:\n'
          '  curl -H "ate-target-actor: substrate-lab/review" http://localhost:18981/status\n'
          '  curl -H "ate-target-actor: substrate-lab/review" http://localhost:18981/egress\n'
          '  curl -H "ate-target-actor: substrate-lab/review" http://localhost:18981/\n'
          'Suspend it before rerunning the tests so the single worker is free:\n'
          '  .runtime/kubectl-ate --kubeconfig .runtime/kubeconfig suspend actor review -a substrate-lab')

def teardown():
    if (STATE / 'owned-cluster').exists():
        for attempt in range(3):
            p = run(['kind', 'delete', 'cluster', '--name', CLUSTER, '--kubeconfig', STATE / 'kubeconfig'], timeout=180, stream=True, check=False)
            if p.returncode == 0:
                break
            if attempt == 2:
                raise RuntimeError('Docker did not finish deleting the owned kind nodes; teardown is incomplete')
            time.sleep(5)
        assert CLUSTER not in run(['kind', 'get', 'clusters']).stdout.splitlines()
        (STATE / 'owned-cluster').unlink()
    p = run(['docker', 'inspect', REGISTRY], check=False)
    if p.returncode == 0:
        assert json.loads(p.stdout)[0]['Config']['Labels'].get('lab') == CLUSTER
        run(['docker', 'rm', '-f', REGISTRY], stream=True)
        assert run(['docker', 'inspect', REGISTRY], check=False).returncode != 0
    print('PASS: lab cluster and registry are absent; evidence retained in .runtime/results', flush=True)

def main():
    steps = {'prepare': prepare, 'install': install, 'baseline': baseline, 'profile': profile,
             'harden': harden, 'test': verify, 'negative': negative, 'review': review, 'teardown': teardown}
    command = sys.argv[1] if len(sys.argv) > 1 else 'up'
    if command == 'up':
        for step in (prepare, install, baseline, profile, harden, verify): step()
    elif command in steps: steps[command]()
    else: raise SystemExit('Usage: quick.sh up|prepare|install|baseline|profile|harden|test|negative|review|teardown')

if __name__ == '__main__':
    main()
