#!/usr/bin/env python3
"""Public CLI selected reads with no workspace and provider mutation recorders."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parents[1]
project = repo / 'cli/nagarectl'
binary = subprocess.check_output(['cabal', 'list-bin', 'exe:nagarectl', '--enable-tests'], cwd=project, text=True).strip()
root = Path(tempfile.mkdtemp(prefix='mp23-selected-observation-'))
context = 'observation-fixture'
siblings = int(os.environ.get('MP23_OBSERVATION_SIBLINGS', '50'))
store = root / 'state/nagare' / context / 'inventory'
subprocess.run(['cabal', 'exec', '--', 'runghc', '-package=nagarectl', '-package=nagare-dsl', '-XGHC2024',
                '-XDeriveAnyClass', '-XDuplicateRecordFields', '-XOverloadedLabels', '-XOverloadedStrings',
                '-itest', str(repo / 'scripts/fixtures/InventoryObservationFixture.hs'), str(store), str(siblings)],
               cwd=project, check=True, timeout=90)
legacy=root/'legacy'
shutil.copytree(store,legacy)
config = root / 'config/nagare'
(config / 'contexts').mkdir(parents=True)
(config / 'kubeconfigs').mkdir()
(config / f'contexts/{context}.env').write_text('CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=local\nNAGARE_INVENTORY_STORE=local\nNAGARE_PLATFORM_VERSION=0.4.0\n')
(config / f'kubeconfigs/{context}.yaml').write_text('apiVersion: v1\nkind: Config\n')
bins = root / 'bin'; bins.mkdir()
calls = root / 'calls.jsonl'; calls.write_text('')
for provider in ['kubectl', 'gcloud', 'helm', 'pulumi', 'nix', 'ssh', 'docker', 'k3d', 'curl']:
    path = bins / provider
    path.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['MP23_CALLS'],'a') as f: f.write(json.dumps([name,*args])+'\\n')
if name=='kubectl' and 'get' in args: sys.exit(0)
if name=='helm' and args[0]=='status':
    print('Error: release: not found',file=sys.stderr); sys.exit(1)
print('unexpected provider command refused',file=sys.stderr); sys.exit(95)
''')
    path.chmod(0o700)
env = {key:value for key,value in os.environ.items() if not key.startswith(('NAGARE_', 'CLOUDSDK_', 'PULUMI_', 'DIRENV_', 'GOOGLE_'))
       and key not in ['KUBECONFIG','XDG_CONFIG_HOME','XDG_STATE_HOME']}
env.update(HOME=str(root/'home'), XDG_CONFIG_HOME=str(root/'config'), XDG_STATE_HOME=str(root/'state'),
           NAGARE_PLATFORM_ROOT=str(root/'no-workspace'), PATH=str(bins)+os.pathsep+env['PATH'], MP23_CALLS=str(calls))
results=[]
def run(label, *args):
    calls.write_text('')
    before=(store/'head.json').read_bytes()
    started=time.monotonic()
    p=subprocess.run([binary,'--context',context,*args], env=env, cwd=root, text=True, capture_output=True, timeout=15)
    entry=dict(label=label,args=args,exit=p.returncode,seconds=round(time.monotonic()-started,3),stdout=p.stdout,stderr=p.stderr,
               providerCalls=[json.loads(line) for line in calls.read_text().splitlines()])
    assert (store/'head.json').read_bytes()==before, entry
    results.append(entry)
    print(json.dumps(entry),flush=True)
    return entry
selected='platform:observation/selected/resource'
helm='platform:observation/helm/resource'
for target,provider in [(selected,'kubectl'),(helm,'helm')]:
    result=run('selected-no-workspace', 'inventory','explain',target,'--json')
    assert result['exit']==0, result
    assert len(result['providerCalls'])==1 and result['providerCalls'][0][0]==provider, result
# Unknown identity must be resolved before any review or workspace access.
for i in range(500):
    content=f'unrelated malformed review {i}'.encode()
    file=store/'reviews'/(hashlib.sha256(content).hexdigest()+'.json')
    file.write_bytes(content); file.chmod(0o600)
result=run('unknown-with-500-bad-reviews','inventory','explain','platform:observation/missing/resource','--json')
assert result['exit']==1 and 'absent from accepted and historical inventory' in result['stderr'] and not result['providerCalls'], result
result=run('selected-with-500-bad-reviews','inventory','explain',selected,'--json')
assert result['exit']==0 and len(result['providerCalls'])==1, result
# Retained selection uses the old scope/native binding, without a workspace.
saved_head=(store/'head.json').read_bytes()
old_head=json.loads(saved_head)
revision=old_head['accepted'][0]
retained_head=dict(old_head,accepted=[],converged=[],retained=[{'resource':selected,'incarnation':{
    'owner':revision['scope'],'revision':revision['revision'],'physical':'retained-uid',
    'retainedAt':'2026-09-29T00:00:00Z'}}])
(store/'head.json').write_text(json.dumps(retained_head,sort_keys=True,separators=(',',':')))
result=run('selected-retained','inventory','explain',selected,'--json')
assert result['exit']==0 and len(result['providerCalls'])==1, result
(store/'head.json').write_bytes(saved_head)
foreign_head=dict(old_head,binding={'identity':context,'project':'different'})
(store/'head.json').write_text(json.dumps(foreign_head,sort_keys=True,separators=(',',':')))
result=run('wrong-context-binding','inventory','explain',selected,'--json')
assert result['exit']==1 and 'different context or project' in result['stderr'] and not result['providerCalls'], result
(store/'head.json').write_bytes(saved_head)
# Remove all irrelevant native objects, retaining just selected unstamped bytes.
head=json.loads((store/'head.json').read_text())
selected_digest=None
for path in (store/'native').glob('*.json'):
    data=json.loads(path.read_text())
    if data.get('kind')=='ConfigMap' and data.get('metadata',{}).get('name')=='selected': selected_digest=path.name
assert selected_digest
for path in (store/'native').glob('*.json'):
    if path.name != selected_digest: path.unlink()
result=run('unrelated-native-absent','inventory','explain',selected,'--json')
assert result['exit']==0 and len(result['providerCalls'])==1, result
(store/'native'/selected_digest).write_text('{}')
result=run('selected-native-corrupt','inventory','explain',selected,'--json')
assert result['exit']==1 and 'digest mismatch' in result['stderr'] and not result['providerCalls'], result
(store/'native'/selected_digest).unlink()
result=run('selected-native-missing','inventory','explain',selected,'--json')
assert result['exit']==1 and 'materialize-native' in result['stderr'] and not result['providerCalls'], result
# A separate untouched fixture models old history: remove only raw bytes, retain
# the immutable mutation envelopes, then explicitly materialize one-review batches.
shutil.rmtree(store)
shutil.copytree(legacy,store)
# Two valid immutable reviews establish that --limit is a real batch boundary.
original_review=next((store/'reviews').glob('*.json'))
document=json.loads(original_review.read_text())
document['payloadIdentity']='another-reviewed-payload'
raw=json.dumps(document,sort_keys=True,separators=(',',':')).encode()
extra=store/'reviews'/(hashlib.sha256(raw).hexdigest()+'.json')
extra.write_bytes(raw); extra.chmod(0o600)
for path in (store/'native').glob('*.json'):
    data=json.loads(path.read_text())
    if 'kind' in data or 'chartPath' in data: path.unlink()
result=run('legacy-fast-miss','inventory','explain',selected,'--json')
assert result['exit']==1 and 'materialize-native' in result['stderr'] and not result['providerCalls'], result
result=run('legacy-materialize','inventory','store','materialize-native','--limit','1')
assert result['exit']==0 and not result['providerCalls'], result
cursor=json.loads(result['stdout'])
assert cursor['processed']==1 and cursor['remaining']==1, cursor
result=run('legacy-restart-cursor','inventory','store','materialize-native','--limit','1','--after',cursor['after'])
assert result['exit']==0 and json.loads(result['stdout'])['processed']==1 and json.loads(result['stdout'])['remaining']==0, result
result=run('legacy-idempotent-repeat','inventory','store','materialize-native','--limit','1')
assert result['exit']==0 and not result['providerCalls'], result
result=run('legacy-materialized-selected','inventory','explain',selected,'--json')
assert result['exit']==0 and len(result['providerCalls'])==1, result
report={'siblingResources':siblings,'scopeBytes':sum(p.stat().st_size for p in (store/'scopes').glob('*.json')),
        'binarySha256':hashlib.sha256(Path(binary).read_bytes()).hexdigest(),'results':results}
(root/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print('PASS: selected observation, early refusal, corrupt evidence, and explicit legacy materialization')
print('Artifacts: '+str(root))
