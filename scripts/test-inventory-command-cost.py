#!/usr/bin/env python3
"""Count complete public no-op resume commands through a local GCS recorder.

This measures command composition, not GCS latency. Every write is rejected.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from inventory_sdk_fixture import StorageFixture, GCLOUD_HELPER

sdk = os.environ.get("MP23_SDK") == "1"
emulator = StorageFixture() if sdk else None

repo=Path(__file__).resolve().parents[1]
binary=subprocess.check_output(['cabal','list-bin','exe:nagarectl','--enable-tests'],cwd=repo/'cli/nagarectl',text=True).strip()
root=Path(tempfile.mkdtemp(prefix='mp23-command-cost-'))
bins=root/'bin'; bins.mkdir()
recorder=bins/'gcloud'
recorder.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['MP23_CALLS'],'a') as f: f.write(json.dumps(args)+'\\n')
objects=json.loads(Path(os.environ['MP23_OBJECTS']).read_text())
if args[:3]==['storage','buckets','describe'] or args[:2]==['projects','describe']: print('12345')
elif args[:3]==['storage','objects','describe']:
    if args[3] not in objects: sys.exit(1)
    print('1')
elif args[:2]==['storage','cp'] and args[2].startswith('gs://audit.invalid/private/'):
    source,destination=args[2:4]
    if source.endswith('/*.json'):
        prefix=source[:-7]
        for key,value in objects.items():
            if key.startswith(prefix+'/') and key.endswith('.json'):
                Path(destination,Path(key).name).write_text(value)
    elif source in objects: Path(destination).write_text(objects[source])
    else: sys.exit(1)
else:
    print('unexpected command or write refused',file=sys.stderr); sys.exit(95)
''')
if sdk:
    recorder.write_text(recorder.read_text().replace("objects=json.loads", GCLOUD_HELPER + "objects=json.loads"))
recorder.chmod(0o700)
for name in ['kubectl','helm','pulumi','nix','ssh','docker']:
    path=bins/name
    path.write_text('#!/bin/sh\nprintf "unexpected provider\\n" >&2\nexit 95\n'); path.chmod(0o700)
canonical=lambda value: json.dumps(value,sort_keys=True,separators=(',',':'))
tx='tx-'+hashlib.sha256(b'no-op-cost-fixture').hexdigest()
binding={'identity':'audit','project':'project'}
baseenv={k:v for k,v in os.environ.items() if not k.startswith(('NAGARE_','CLOUDSDK_','PULUMI_','DIRENV_','GOOGLE_'))
         and k not in ['KUBECONFIG','XDG_CONFIG_HOME','XDG_STATE_HOME','XDG_CACHE_HOME']}
results=[]
for events in [50,500]:
    for reviews in [0,50,500]:
        case=root/f'events-{events}-reviews-{reviews}'; case.mkdir()
        config=case/'config/nagare/contexts'; config.mkdir(parents=True)
        (config/'audit.env').write_text('CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=cloud\nNAGARE_INVENTORY_STORE=gcs\nNAGARE_INVENTORY_STORE_URL=gs://audit.invalid/private\n')
        objects={}
        def put(key,value): objects['gs://audit.invalid/private/'+key]=canonical(value)
        put('format.json',{'version':1,'binding':binding})
        put('head.json',{'version':1,'generation':1,'sequence':events,'binding':binding,'clientIdentity':'fixture',
                        'accepted':[],'converged':[],'activeTransaction':None,'executorClaim':None})
        prior=None
        for sequence in range(events):
            event={'version':1,'sequence':sequence,'previousDigest':prior,'transaction':tx,
                   'operation':None,'state':{'tag':'Pending'},'timestamp':'2026-09-29T00:00:00Z',
                   'detail':'transaction converged' if sequence==events-1 else 'fixture history'}
            put(f'journal/{sequence:020d}.json',event)
            prior=hashlib.sha256(canonical(event).encode()).hexdigest()
        for i in range(reviews): put('reviews/'+hashlib.sha256(str(i).encode()).hexdigest()+'.json',{})
        objectfile=case/'objects.json'; objectfile.write_text(json.dumps(objects))
        calls=case/'calls.jsonl'
        env=dict(baseenv,HOME=str(case/'home'),XDG_CONFIG_HOME=str(case/'config'),XDG_STATE_HOME=str(case/'state'),
                 XDG_CACHE_HOME=str(case/'cache'),NAGARE_PLATFORM_ROOT=str(case/'no-workspace'),
                 PATH=str(bins)+os.pathsep+baseenv['PATH'],MP23_CALLS=str(calls),MP23_OBJECTS=str(objectfile))
        if not sdk: env['NAGARE_INVENTORY_GCS_TRANSPORT'] = 'gcloud'
        if sdk: env['CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE'] = emulator.endpoint
        for temperature in ['cold','warm']:
            if sdk: emulator.reset({key: {'generation': 1, 'bytes': value} for key, value in objects.items()})
            calls.write_text(''); started=time.monotonic()
            p=subprocess.run([binary,'--context','audit','inventory','resume',tx,'--yes'],env=env,cwd=case,
                             capture_output=True,text=True,timeout=20)
            commands=[json.loads(line) for line in calls.read_text().splitlines()]
            batches=[c for c in commands if c[:2]==['storage','cp'] and c[2].endswith('/journal/*.json')]
            result=dict(events=events,reviews=reviews,temperature=temperature,exit=p.returncode,
                        seconds=round(time.monotonic()-started,3),subprocesses=len(commands),journalBatches=len(batches),
                        stdout=p.stdout,stderr=p.stderr,commands=commands)
            if sdk: result['http'] = list(emulator.calls)
            results.append(result)
            print(json.dumps({k:v for k,v in result.items() if k not in ['commands', 'http']}),flush=True)
            assert p.returncode==0 and 'converged '+tx in p.stdout, result
            if sdk:
                assert sum(c['query'].get('alt') == 'media' and '/private%2Fjournal%2F' in c['path'] for c in emulator.calls) == events
                assert not any(c['method'] != 'GET' for c in emulator.calls)
                assert not batches
            else: assert len(batches)==1, result
            assert not any('/reviews/' in ' '.join(c) or c[:3]==['storage','objects','list'] for c in commands), result
            assert json.loads(objectfile.read_text())==objects, result
assert {r['subprocesses'] for r in results}==({3} if sdk else {12}), results
(root/'result.json').write_text(json.dumps({'binarySha256':hashlib.sha256(Path(binary).read_bytes()).hexdigest(),'results':results},indent=2)+'\n')
print('PASS: public no-op resume has constant transport cost across 50/500 events and 0/50/500 unrelated reviews')
print('Artifacts: '+str(root))

if emulator: emulator.close()
