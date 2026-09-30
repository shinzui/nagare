#!/usr/bin/env python3
"""Bounded installed two-root consumer proof. Never runs cluster apply."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import time

parser = argparse.ArgumentParser(__doc__)
for name in ['binary', 'source-config', 'context', 'project', 'gcloud-configuration', 'zone', 'ssh-key', 'cluster-inputs', 'out']:
    parser.add_argument('--'+name, required=True)
parser.add_argument('--expected-node-uid')
args = parser.parse_args()
root = Path(args.out)
if root.exists():
    parser.error('evidence root already exists; do not overwrite a previous experiment')
os.umask(0o077)
root.mkdir(mode=0o700)
source = Path(args.source_config)/'nagare'
profiles = root/'config/nagare/contexts'
profiles.mkdir(parents=True)
shutil.copy2(source/'contexts'/f'{args.context}.env', profiles/f'{args.context}.env')
shutil.copytree(source/'hosts'/args.context, root/'config/nagare/hosts'/args.context)
# No journal, migration marker, Pulumi config or credential crosses roots.
env = {k: os.environ[k] for k in ['HOME', 'USER', 'PATH'] if k in os.environ}
env.update(CLOUDSDK_CORE_PROJECT=args.project, CLOUDSDK_ACTIVE_CONFIG_NAME=args.gcloud_configuration,
           CLOUDSDK_CORE_DISABLE_FILE_LOGGING='true', CLOUDSDK_CORE_DISABLE_PROMPTS='true',
           CLOUDSDK_COMPUTE_ZONE=args.zone, ZONE=args.zone, SSH_KEY=args.ssh_key,
           IAP_MAX_ATTEMPTS='1', XDG_CONFIG_HOME=str(root/'config'),
           XDG_STATE_HOME=str(root/'state'), XDG_CACHE_HOME=str(root/'cache'))
values = json.loads(Path(args.cluster_inputs).read_text())
allowed = {'NAGARE_AUTH_EN_IMAGE', 'NAGARE_AUTH_SHOMEI_IMAGE', 'NAGARE_AUTH_ACCESS_IMAGE',
           'NAGARE_CLUSTER_SECRETS_DIR', 'SOPS_AGE_KEY_FILE'}
assert set(values) <= allowed
env.update(values)
credential = root/'config/nagare/kubeconfigs'/f'{args.context}.yaml'
env['KUBECONFIG'] = str(credential)

def global_contexts():
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None
            for p in [Path.home()/'.config/gcloud/active_config', Path.home()/'.kube/config']}

results = []
before_global = global_contexts()

def run(label, command, budget):
    start = time.monotonic()
    with (root/(label+'.stdout')).open('w') as out, (root/(label+'.stderr')).open('w') as err:
        p = subprocess.Popen(command, env=env, cwd=root, stdout=out, stderr=err, start_new_session=True)
        print(json.dumps({'label': label, 'pid': p.pid, 'budget': budget}), flush=True)
        try:
            code = p.wait(timeout=budget)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGTERM)
            p.wait(timeout=10)
            code = 124
    result = {'label': label, 'exit': code, 'seconds': round(time.monotonic()-start, 3)}
    results.append(result)
    (root/'steps.json').write_text(json.dumps(results, indent=2)+'\n')
    print(json.dumps(result), flush=True)
    return code

cli = [args.binary, '--context', args.context]
try:
    assert run('before', cli+['inventory', 'store', 'status', '--json'], 60) == 0
    before = json.loads((root/'before.stdout').read_text())
    assert run('credential-plan', cli+['platform', 'bootstrap', 'plan', '--out', str(root/'credential-review')], 120) != 0
    assert 'accepted kubeconfig is absent in this context root' in (root/'credential-plan.stderr').read_text()
    assert not (root/'credential-review').exists()
    assert not (root/'state/nagare'/args.context/'inventory/head.json').exists()
    assert run('credential-recovery', cli+['kubeconfig', 'recover'], 120) == 0
    assert stat.S_IMODE(credential.stat().st_mode) == 0o600
    assert run('node', ['kubectl', '--kubeconfig', str(credential), '--context', args.context,
                        'get', 'nodes', '-o', 'json', '--request-timeout=10s'], 30) == 0
    nodes = json.loads((root/'node.stdout').read_text())['items']
    assert len(nodes) == 1 and any(c['type']=='Ready' and c['status']=='True'
                                 for c in nodes[0]['status']['conditions'])
    if args.expected_node_uid:
        assert nodes[0]['metadata']['uid'] == args.expected_node_uid
    assert run('cluster-plan', cli+['platform', 'bootstrap', 'plan', '--out', str(root/'cluster-review')], 360) == 0
    review = json.loads((root/'cluster-review/review.json').read_text())
    forbidden = {'CloudFoundationExecutor', 'PulumiExecutor', 'HostExecutor'}
    assert not any(op['operation']['executor'] in forbidden for op in review['operations'])
    preserved = {'cloud-foundation', 'cloud', 'host-image-build', 'host-image', 'host', 'kubeconfig'}
    assert {entry['scope']['name'] for entry in review['baseRevisions']} == preserved
    assert not any(resource.startswith('platform:'+owner+'/') for owner in preserved
                   for op in review['operations'] for resource in op['operation']['resources'])
    assert not review['barriers']
    assert run('after', cli+['inventory', 'store', 'status', '--json'], 60) == 0
    after = json.loads((root/'after.stdout').read_text())
    assert before == after, 'shared head/status changed'
    assert global_contexts() == before_global, 'global context changed'
    summary = {'steps': results, 'reviewOperations': len(review['operations']),
               'reviewDigest': hashlib.sha256((root/'cluster-review/review.json').read_bytes()).hexdigest(),
               'globalContextsUnchanged': True, 'sharedStatusUnchanged': True,
               'localInventoryAbsent': not (root/'state/nagare'/args.context/'inventory').exists(),
               'copiedMarkerOrJournalOrCredential': False, 'clusterApply': False,
               'nodeUid': nodes[0]['metadata']['uid']}
    (root/'result.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps(summary), flush=True)
finally:
    (root/'global-contexts.json').write_text(json.dumps({'before': before_global, 'after': global_contexts()}, indent=2)+'\n')
