#!/usr/bin/env python3
"""Bounded, read-only SDK command against the retained disposable GCS history.

No transaction resume/apply, provider observation, or global context switch.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

repo=Path(__file__).resolve().parents[1]
binary=repo/'cli/nagarectl/dist-newstyle/build/aarch64-osx/ghc-9.12.4/nagarectl-0.4.0/x/nagarectl/build/nagarectl/nagarectl'
fixture=json.loads((repo/'fixtures/inventory-release/gcp/ep150-target.json').read_text())
root=Path(tempfile.mkdtemp(prefix='mp23-sdk-readonly-'))
profile=root/'config/nagare/contexts/ep150-preview.env';profile.parent.mkdir(parents=True)
project='tan-ng-labs'; url='gs://tan-ng-labs-ep150-pmkjjpp-state/inventory'
profile.write_text(f'CLOUDSDK_CORE_PROJECT={project}\nNAGARE_MODE=cloud\nNAGARE_INVENTORY_STORE=gcs\nNAGARE_INVENTORY_STORE_URL={url}\n')
profile.chmod(0o600)
base={k:v for k,v in os.environ.items() if not k.startswith(('NAGARE_','CLOUDSDK_','GOOGLE_','PULUMI_','DIRENV_')) and k not in ['KUBECONFIG','XDG_CONFIG_HOME','XDG_STATE_HOME','XDG_CACHE_HOME']}
env=dict(base,CLOUDSDK_CONFIG=os.environ.get('CLOUDSDK_CONFIG',str(Path.home()/'.config/gcloud')),CLOUDSDK_CORE_PROJECT=project,CLOUDSDK_ACTIVE_CONFIG_NAME=fixture['gcloudConfiguration'],CLOUDSDK_CORE_LOG_HTTP='false',CLOUDSDK_CORE_DISABLE_FILE_LOGGING='true',XDG_CONFIG_HOME=str(root/'config'),XDG_STATE_HOME=str(root/'state'),XDG_CACHE_HOME=str(root/'cache'),NAGARE_PLATFORM_ROOT=str(root/'no-workspace'))

def head():
    p=subprocess.run(['gcloud','storage','objects','describe',url+'/head.json','--raw','--format=json(generation,size)','--quiet'],env=env,capture_output=True,text=True,timeout=15)
    if p.returncode: raise RuntimeError('read-only head metadata probe failed; private output withheld')
    return json.loads(p.stdout)

before=head()
rows=[]
for temperature in ['cold','warm']:
    start=time.monotonic()
    p=subprocess.run([str(binary),'--context','ep150-preview','inventory','explain','standalone:mp23-sdk-probe/absent/resource','--json'],env=env,cwd=root,capture_output=True,text=True,timeout=25)
    row={'temperature':temperature,'exit':p.returncode,'seconds':round(time.monotonic()-start,3),'expectedAbsentResourceRefusal':p.returncode==1 and 'resource is absent from accepted and historical inventory' in p.stderr,'stdoutEmpty':not p.stdout}
    print(json.dumps(row),flush=True)
    if not row['expectedAbsentResourceRefusal']:
        raise RuntimeError('read-only CLI failed before the expected absent-resource refusal: '+p.stderr[:500])
    rows.append(row)
after=head()
assert before==after,(before,after)
report={'binarySha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'operation':'inventory explain absent resource; read-only store','project':project,'url':url,'headBefore':before,'headAfter':after,'globalContextChanges':0,'results':rows}
(root/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print('PASS: cold/warm SDK CLI reads retained history; expected target refusal; head generation unchanged')
print('Artifacts: '+str(root))
