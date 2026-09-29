#!/usr/bin/env python3
"""Actual CLI against synthetic admitted history and refusing provider recorders."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
repo = Path(__file__).resolve().parents[3]
if len(sys.argv) == 2:
    root = Path(sys.argv[1])
else:
    generated = subprocess.run([sys.executable, str(Path(__file__).with_name('run-operational-cost.py')), 'prune-fixture'],
                               text=True, capture_output=True, timeout=95, check=True)
    print(generated.stdout)
    root = Path(re.search(r'^Artifacts: (.+)$', generated.stdout, re.M)[1]) / 'fixture-prune-fixture'
binary = subprocess.check_output(['cabal', 'list-bin', 'exe:nagarectl'], cwd=repo/'cli/nagarectl', text=True).strip()
check = subprocess.run(['cabal','build','exe:nagarectl','--dry-run'],cwd=repo/'cli/nagarectl',text=True,capture_output=True,timeout=30,check=True)
assert 'Up to date' in check.stdout, check.stdout + check.stderr
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
            value['status']={'conditions':[{'type':'Failed' if entry['prune'] else 'Complete','status':'True'}]}
        print(json.dumps(value)); sys.exit(0)
print('unexpected provider command refused: '+name+' '+str(args),file=sys.stderr)
sys.exit(95)
'''
for provider in ['kubectl','gcloud','helm','pulumi','nix','ssh','docker','k3d','curl','aws','mc']:
    p=bins/provider; p.write_text(recorder); p.chmod(0o700)
baseenv={k:v for k,v in os.environ.items() if not k.startswith(('NAGARE_','CLOUDSDK_','PULUMI_','DIRENV_','GOOGLE_'))
         and k not in ['KUBECONFIG','XDG_CONFIG_HOME','XDG_STATE_HOME']}
results=[]
for phase in ['before','partial','wrong-source-uid']:
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
    # Model the provider stage explicitly; the CLI must not rerun either deletion.
    provider_state={'backupVersion':'17' if phase=='before' else None,'receiptVersion':'19'}
    (case/'provider-state.json').write_text(json.dumps(provider_state))
    commands=[['inventory','resume',fixture['transaction'],'--yes']]
    if phase!='before':
        commands += [['inventory','recover',fixture['transaction'],'--operation',fixture['operation'],'--decision',str(root/'decision.json')]]
        if phase=='partial': commands += [['inventory','resume',fixture['transaction'],'--yes']]
    for args in commands:
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
    assert json.loads((case/'provider-state.json').read_text())==provider_state
before, partial_resume, partial_recover, partial_closed, changed_resume, changed_recover = results
assert before['exit'] == 1 and 'ambiguous ' in before['stdout']
assert sum('create' in c for c in before['providerCalls']) == 1
assert partial_resume['exit'] == 1 and 'declared Kubernetes Job is not complete' in partial_resume['stderr']
assert partial_resume['beforeHead']['sequence'] == partial_resume['afterHead']['sequence']
assert partial_recover['exit'] == 0 and partial_recover['afterHead']['activeTransaction'] is None
assert partial_recover['afterHead']['sequence'] == partial_recover['beforeHead']['sequence'] + 1
assert changed_recover['exit'] == 1 and 'unsupported-recovery' in changed_recover['stderr']
assert changed_recover['afterHead']['activeTransaction'] == fixture['transaction']
assert changed_recover['afterHead']['sequence'] == changed_recover['beforeHead']['sequence']
assert partial_closed['exit'] == 1 and 'inactive-transaction' in partial_closed['stderr'] and not partial_closed['providerCalls']
for result in results[1:]:
    assert all(c[0] == 'kubectl' and 'get' in c for c in result['providerCalls']), result
report={'binarySha256':hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
        'mainSourceSha256':hashlib.sha256((repo/'cli/nagarectl/app/Main.hs').read_bytes()).hexdigest(),
        'fixture':fixture,'results':results}
(root/'prune-cli.json').write_text(json.dumps(report,indent=2)+'\n')
print('Artifacts: '+str(root))
