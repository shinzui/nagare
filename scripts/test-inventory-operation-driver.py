#!/usr/bin/env python3
"""Regression: fresh CLI processes recover the saved two-operation prune review. Provider mutations are refused; this proves orchestration, not physical deletion."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
repo = Path(__file__).resolve().parents[1]
binary = subprocess.check_output(['cabal', 'list-bin', 'exe:nagarectl', '--enable-tests'], cwd=repo/'cli/nagarectl', text=True).strip()
check = subprocess.run(['cabal','build','exe:nagarectl','test:nagarectl-test','--enable-tests','--dry-run'],cwd=repo/'cli/nagarectl',text=True,capture_output=True,timeout=30,check=True)
assert 'Up to date' in check.stdout, check.stdout + check.stderr
if len(sys.argv) == 2:
    root = Path(sys.argv[1])
else:
    generated = subprocess.run([sys.executable, str(repo/'docs/audits/mp23-reproductions/run-operational-cost.py'), 'prune-fixture'],
                               text=True, capture_output=True, timeout=95, check=True)
    print(generated.stdout)
    root = Path(re.search(r'^Artifacts: (.+)$', generated.stdout, re.M)[1]) / 'fixture-prune-fixture'
fixture = json.loads((root/'fixture.json').read_text())
payload = root/'payload'
# Minimal valid workspace assets. None is invoked as executable/provider logic.
for relative in ['release.json','cli/nagare-dsl/nagare-dsl.cabal','cli/nagare-access/nagare-access.cabal',
                 'cli/nagare-access/Dockerfile','infra/pulumi/Pulumi.yaml','cluster/bootstrap/render-context-template.sh',
                 'nixos/flake.nix','scripts/lib/target.sh','justfile','docs/user/reference.md',
                 'docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md',
                 'docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md']:
    target=payload/relative
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text('offline fixture\n')
(payload/'release.json').write_bytes((repo/'release.json').read_bytes())
for relative in ['cluster/examples','cluster/observability','cluster/local','docs/runbooks']:
    (payload/relative).mkdir(parents=True,exist_ok=True)
bins=root/'recorders'; bins.mkdir(exist_ok=True)
recorder=r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['MP23_CALLS'],'a') as f: f.write(json.dumps([name,*args])+'\n')
if name=='kubectl' and 'get' in args:
    i=args.index('get'); kind=args[i+1]; requested=args[i+2]
    fixture=json.loads(Path(os.environ['MP23_FIXTURE']).read_text())
    for entry in fixture['entries']:
        value=entry['native']; meta=value['metadata']
        if meta['name']!=requested: continue
        if entry['prune'] and os.environ['MP23_PRUNE_PHASE']=='before': sys.exit(0)
        annotations=meta.setdefault('annotations',{})
        annotations.update({'nagare.dev/context-id':'prune-spike','nagare.dev/resource-id':entry['id'],
                            'nagare.dev/spec-digest':entry['digest']})
        meta.update(uid=entry['uid'],resourceVersion='7')
        if not entry['prune'] and os.environ['MP23_PRUNE_PHASE']=='wrong-source-uid': meta['uid']='foreign-ingestion-uid'
        if value['kind']=='Job':
            value['status']={'conditions':[{'type':'Failed' if entry['prune'] and os.environ['MP23_PRUNE_PHASE'] not in ['completed','running'] else 'Complete','status':'True'}]}
        if entry['prune'] and os.environ['MP23_PRUNE_PHASE']=='running': value['status']={}
        print(json.dumps(value)); sys.exit(0)
print('unexpected provider command refused: '+name+' '+str(args),file=sys.stderr)
sys.exit(95)
'''
for provider in ['kubectl','gcloud','helm','pulumi','nix','ssh','docker','k3d','curl','aws','mc']:
    p=bins/provider; p.write_text(recorder); p.chmod(0o700)
baseenv={k:v for k,v in os.environ.items() if not k.startswith(('NAGARE_','CLOUDSDK_','PULUMI_','DIRENV_','GOOGLE_'))
         and k not in ['KUBECONFIG','XDG_CONFIG_HOME','XDG_STATE_HOME']}
results=[]
for phase in ['before','partial','wrong-source-uid','completed','running']:
    case=root/('case-'+phase+'-'+str(time.time_ns()))
    shutil.copytree(root/'state',case/'state')
    config=case/'config/nagare'
    (config/'contexts').mkdir(parents=True)
    (config/'kubeconfigs').mkdir()
    (config/'contexts/prune-spike.env').write_text('CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=local\nNAGARE_INVENTORY_STORE=local\nNAGARE_PLATFORM_VERSION=0.4.0\n')
    (config/'kubeconfigs/prune-spike.yaml').write_text('apiVersion: v1\nkind: Config\n')
    calls=case/'calls.jsonl'; calls.write_text('')
    env=dict(baseenv, HOME=str(case/'home'),XDG_CONFIG_HOME=str(case/'config'),XDG_STATE_HOME=str(case/'state'),
             NAGARE_PLATFORM_ROOT=str(payload),PATH=str(bins)+os.pathsep+baseenv['PATH'],
             MP23_CALLS=str(calls),MP23_FIXTURE=str(root/'fixture.json'),MP23_PRUNE_PHASE=phase)
    store=case/'state/nagare/prune-spike/inventory'
    commands=[['inventory','resume',fixture['transaction'],'--yes']]
    if phase in ['partial','wrong-source-uid']:
        commands += [['inventory','recover',fixture['transaction'],'--operation',fixture['operation'],'--decision',str(root/'decision.json')]]
        if phase=='partial': commands += [['inventory','resume',fixture['transaction'],'--yes']]
    if phase=='completed': commands += [['inventory','resume',fixture['transaction'],'--yes']]
    if phase=='running': commands += [['inventory','resume',fixture['transaction'],'--yes'], ['inventory','resume',fixture['transaction'],'--yes']]
    for command_index, args in enumerate(commands):
        if phase=='running' and command_index>0: env['MP23_PRUNE_PHASE']='completed'
        before=json.loads((store/'head.json').read_text())
        started=time.monotonic()
        p=subprocess.run([binary,'--context','prune-spike',*args],env=env,cwd=case,text=True,capture_output=True,timeout=15)
        after=json.loads((store/'head.json').read_text())
        entry={'phase':phase,'args':args,'exit':p.returncode,'seconds':round(time.monotonic()-started,3),
               'stdout':p.stdout,'stderr':p.stderr,'beforeHead':before,'afterHead':after,
               'providerCalls':[json.loads(line) for line in calls.read_text().splitlines()]}
        results.append(entry)
        print(json.dumps({k:v for k,v in entry.items() if k not in ['beforeHead','afterHead','providerCalls']}),flush=True)
        calls.write_text('')
by_phase = {phase: [r for r in results if r['phase']==phase] for phase in ['before','partial','wrong-source-uid','completed','running']}
before, = by_phase['before']
partial_resume, partial_recover, partial_closed = by_phase['partial']
changed_resume, changed_recover = by_phase['wrong-source-uid']
assert before['exit'] == 1 and 'stopped ' in before['stdout'], before
assert 'NAGARE_LOCAL_OBJECT_STORE' in before['stderr'], before
assert 'KnownNoEffect' in before['stdout'], before
assert not any('create' in c for c in before['providerCalls']), before
assert before['beforeHead']['sequence'] == before['afterHead']['sequence']
assert before['afterHead']['activeTransaction'] == fixture['transaction']
for stopped in [partial_resume, changed_resume, by_phase['running'][0]]:
    assert stopped['exit'] == 1 and 'ambiguous ' in stopped['stdout'], stopped
    assert not stopped['stderr'], stopped
    assert stopped['beforeHead']['sequence'] == stopped['afterHead']['sequence']
    assert stopped['afterHead']['activeTransaction'] == fixture['transaction']
assert partial_recover['exit'] == 0 and partial_recover['afterHead']['activeTransaction'] is None
assert partial_recover['afterHead']['sequence'] == partial_recover['beforeHead']['sequence'] + 1
assert changed_recover['exit'] == 1 and 'unsupported-recovery' in changed_recover['stderr']
assert changed_recover['afterHead']['activeTransaction'] == fixture['transaction']
assert changed_recover['afterHead']['sequence'] == changed_recover['beforeHead']['sequence']
assert partial_closed['exit'] == 1 and 'inactive-transaction' in partial_closed['stderr'] and not partial_closed['providerCalls']
for phase in ['completed','running']:
    converged, replay = by_phase[phase][-2:]
    assert converged['exit']==0 and 'converged ' in converged['stdout'], converged
    assert converged['afterHead']['activeTransaction'] is None
    assert converged['afterHead']['accepted']==converged['afterHead']['converged']
    assert replay['exit']==0 and 'converged ' in replay['stdout'] and not replay['providerCalls'], replay
    assert replay['beforeHead']==replay['afterHead'], replay
for result in results:
    assert all(c[0] == 'kubectl' and 'get' in c for c in result['providerCalls']), result
report={'binarySha256':hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
        'sources':{p:hashlib.sha256((repo/p).read_bytes()).hexdigest() for p in [
            'cli/nagarectl/app/Main.hs','cli/nagarectl/src/Nagare/Inventory/Execute.hs',
            'cli/nagarectl/src/Nagare/Inventory/OperationStep.hs',
            'cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs',
            'cli/nagarectl/test/InventoryTransactionSpec.hs','cli/nagarectl/nagarectl.cabal',
            'scripts/test-inventory-operation-driver.py',
            'docs/audits/mp23-reproductions/PruneFixture.hs']},
        'fixture':fixture,'results':results}
(root/'rescue-cli.json').write_text(json.dumps(report,indent=2)+'\n')
print('PASS: saved prune recovery, completion, interruption, changed UID and replay; provider effects refused')
print('Artifacts: '+str(root))
