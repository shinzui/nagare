#!/usr/bin/env python3
"""Actual CLI migration and refusal tests against loopback storage only."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from inventory_sdk_fixture import StorageFixture, GCLOUD_HELPER

repo = Path(__file__).resolve().parents[1]
binary = subprocess.check_output(['cabal', 'list-bin', 'exe:nagarectl', '--enable-tests'], cwd=repo/'cli/nagarectl', text=True).strip()
root = Path(tempfile.mkdtemp(prefix='mp23-sdk-migration-'))
bins = root/'bin'; bins.mkdir()
recorder = '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['MP23_CALLS'],'a') as f: f.write(json.dumps(args)+'\\n')
''' + GCLOUD_HELPER + '''
if args[:3]==['storage','buckets','describe']: print('999' if os.environ.get('MP23_FOREIGN_BUCKET') else '12345')
elif args[:2]==['projects','describe']: print('12345')
else: sys.exit(95)
'''
(bins/'gcloud').write_text(recorder); (bins/'gcloud').chmod(0o700)
for name in ['kubectl','helm','pulumi','nix','ssh','docker','curl']:
    p=bins/name; p.write_text('#!/bin/sh\nexit 95\n'); p.chmod(0o700)
profile = root/'config/nagare/contexts/audit.env'; profile.parent.mkdir(parents=True)
profile.write_text('CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=cloud\nNAGARE_INVENTORY_STORE=local\nNAGARE_INVENTORY_STORE_URL=gs://audit.invalid/private\n')
store=root/'state/nagare/audit/inventory'; (store/'journal').mkdir(parents=True)
canonical=lambda value: json.dumps(value,sort_keys=True,separators=(',',':'))
tx='tx-'+hashlib.sha256(b'sdk-migration').hexdigest()
binding={'identity':'audit','project':'project'}
head={'version':1,'generation':1,'sequence':1,'binding':binding,'clientIdentity':'fixture', 'accepted':[],'converged':[],'activeTransaction':None,'executorClaim':None}
event={'version':1,'sequence':0,'previousDigest':None,'transaction':tx,'operation':None,'state':{'tag':'Pending'},'timestamp':'2026-09-29T00:00:00Z','detail':'transaction converged'}
(store/'head.json').write_text(canonical(head))
(store/'journal/00000000000000000000.json').write_text(canonical(event))
for private in [store/'head.json', store/'journal/00000000000000000000.json']: private.chmod(0o600)
store.chmod(0o700); (store/'journal').chmod(0o700)
calls=root/'calls.jsonl'; calls.write_text('')
base={k:v for k,v in os.environ.items() if not k.startswith(('NAGARE_','CLOUDSDK_','GOOGLE_','PULUMI_','DIRENV_')) and k not in ['KUBECONFIG','XDG_CONFIG_HOME','XDG_STATE_HOME','XDG_CACHE_HOME']}
emulator=StorageFixture()
env=dict(base,HOME=str(root/'home'),PATH=str(bins)+os.pathsep+base['PATH'],XDG_CONFIG_HOME=str(root/'config'),XDG_STATE_HOME=str(root/'state'),XDG_CACHE_HOME=str(root/'cache'),NAGARE_PLATFORM_ROOT=str(root/'missing-workspace'),CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE=emulator.endpoint,MP23_CALLS=str(calls))
results=[]

def run(label,args,extra=None):
    calls.write_text(''); emulator.calls=[]
    start=time.monotonic()
    p=subprocess.run([binary,'--context','audit',*args],env=dict(env,**(extra or {})),cwd=root,text=True,capture_output=True,timeout=20)
    result=dict(label=label,exit=p.returncode,seconds=round(time.monotonic()-start,3),stdout=p.stdout,stderr=p.stderr,commands=[json.loads(line) for line in calls.read_text().splitlines()],http=list(emulator.calls))
    results.append(result)
    print(json.dumps({k:v for k,v in result.items() if k not in ['commands','http']}),flush=True)
    return result

try:
    emulator.reset({},head_only=False,lost_ack=True)
    ready=run('local-to-gcs-dry-run',['inventory','store','migrate','--to','gcs','--dry-run'])
    assert ready['exit']==0,ready
    assert not emulator.objects and all(c['method']=='GET' for c in ready['http'])
    migrated=run('local-to-gcs-lost-ack',['inventory','store','migrate','--to','gcs','--yes'])
    assert migrated['exit']==0,migrated
    assert 'NAGARE_INVENTORY_STORE=gcs' in profile.read_text().replace(chr(39), '').replace(chr(34), '')
    assert json.loads((store/'head.json').read_text()).get('migration') is not None
    assert emulator.objects['gs://audit.invalid/private/journal/00000000000000000000.json']['bytes']==canonical(event)
    replay=run('gcs-replay',['inventory','resume',tx,'--yes'])
    assert replay['exit']==0 and 'converged '+tx in replay['stdout'],replay
    for label,extra in [('foreign-project',{'CLOUDSDK_CORE_PROJECT':'foreign'}),('foreign-bucket',{'MP23_FOREIGN_BUCKET':'1'}),('unsupported-credentials',{'CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE':'private-path'})]:
        result=run(label,['inventory','resume',tx,'--yes'],extra)
        assert result['exit']!=0 and not result['http'],result
        assert 'private-path' not in result['stderr']
    emulator.denied=True
    denied=run('forbidden-is-not-absence',['inventory','resume',tx,'--yes'])
    assert denied['exit']!=0 and all(c['method']=='GET' for c in denied['http']),denied
    emulator.denied=False
    ready=run('gcs-to-local-dry-run',['inventory','store','migrate','--to','local','--dry-run'])
    assert ready['exit']==0,ready
    assert all(c['method']=='GET' for c in ready['http'])
    returned=run('gcs-to-local',['inventory','store','migrate','--to','local','--yes'])
    assert returned['exit']==0,returned
    assert 'NAGARE_INVENTORY_STORE=local' in profile.read_text().replace(chr(39), '').replace(chr(34), '')
    assert (store/'journal/00000000000000000000.json').read_text()==canonical(event)
    replay=run('local-replay',['inventory','resume',tx,'--yes'])
    assert replay['exit']==0 and 'converged '+tx in replay['stdout'] and not replay['http'] and not replay['commands'],replay
    (root/'result.json').write_text(json.dumps({'binarySha256':hashlib.sha256(Path(binary).read_bytes()).hexdigest(),'results':results},indent=2)+'\n')
    print('PASS: SDK migration, lost acknowledgements, replay, and pre-effect refusals')
    print('Artifacts: '+str(root))
finally:
    emulator.close()
