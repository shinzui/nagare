#!/usr/bin/env python3
"""Recording-provider diagnostic: no real cloud or Kubernetes calls.

Each subprocess has fresh config/state/cache and a 30-second read-only budget.
The output records current behavior; it does not assert the defect is repaired.
"""
import argparse, json, os, signal, subprocess, time
from pathlib import Path

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--platform-root', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args=parser.parse_args()
root=args.out.resolve()
assert not root.exists(), 'preserve evidence'
assert args.binary.is_absolute(), 'select an absolute executable path'
assert args.platform_root.is_dir(), 'selected payload or source checkout missing'
root.mkdir(mode=0o700)
cli=str(args.binary)
platform_root=str(args.platform_root.resolve())
mock = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
a=sys.argv[1:]; mode=os.environ['PROBE_CASE']
with open(os.environ['PROBE_TRACE'],'a') as f: f.write(json.dumps(a)+'\\n')
if a==['auth','list','--filter=status:ACTIVE','--format=value(account)']: print('fixture@example.invalid')
elif a==['config','get-value','project']: print('fixture-project')
elif a[:3]==['projects','describe','fixture-project']: print('12345')
elif a[:3]==['services','list','--enabled']:
 print(json.dumps([{'config':{'name':s+'.googleapis.com'}} for s in ['compute','dns','storage','artifactregistry','certificatemanager','iam','servicenetworking']]))
elif a[:3]==['storage','buckets','list']:
 if mode=='list-unavailable': sys.exit(1)
 print('[]')
elif a[:3]==['storage','buckets','describe']:
 if mode in ['bucket-unavailable','bucket-absent','list-unavailable']: sys.exit(1)
 print('99999' if mode=='foreign-bucket' else '12345')
elif a[:3]==['storage','objects','describe']:
 if mode in ['foreign-format','foreign-head'] or (mode=='head-missing' and a[3].endswith('format.json')): print('1')
 else: sys.exit(1)
elif a[:3]==['storage','objects','list']:
 if mode=='prefix-unavailable': sys.exit(1)
 print(json.dumps([{'name':'nagare/fresh/inventory/head.json'}]) if mode=='format-missing-with-head' else '[]')
elif a[:2]==['storage','cp'] and a[2].startswith('gs://') and mode in ['foreign-format','foreign-head','head-missing']:
 if a[2].endswith('format.json'):
  value={'binding':{'identity':'foreign' if mode=='foreign-format' else 'fresh','project':'fixture-project'},'version':1}
 else:
  value={'accepted':[],'activeTransaction':None,'binding':{'identity':'foreign','project':'fixture-project'},'clientIdentity':'fixture-client','converged':[],'executorClaim':None,'generation':1,'sequence':0,'version':1}
 Path(a[3]).write_text(json.dumps(value,sort_keys=True,separators=(',',':')))
else:
 print('unexpected command refused',file=sys.stderr);sys.exit(37)
'''
(root/'bin').mkdir()
(root/'bin'/'gcloud').write_text(mock);(root/'bin'/'gcloud').chmod(0o700)
for name in ['pulumi','kubectl']:
 (root/'bin'/name).write_text('#!/bin/sh\nexit 38\n');(root/'bin'/name).chmod(0o700)
results=[]
for case in ['bucket-absent','foreign-bucket','bucket-unavailable','list-unavailable','prefix-absent','prefix-unavailable','foreign-format','foreign-head','head-missing','format-missing-with-head']:
 for command in (['status','plan'] if case in ['bucket-absent','foreign-bucket','bucket-unavailable','list-unavailable'] else ['status']):
  here=root/case/command;(here/'config/nagare/contexts').mkdir(parents=True)
  (here/'config/nagare/contexts/fresh.env').write_text('CLOUDSDK_CORE_PROJECT=fixture-project\nCLOUDSDK_COMPUTE_REGION=us-west1\nNAGARE_MODE=cloud\nNAGARE_PULUMI_BACKEND=gcs\nNAGARE_INVENTORY_STORE=gcs\nNAGARE_PLATFORM_VERSION=0.4.0\n')
  env={k:os.environ[k] for k in ['HOME','USER','PATH'] if k in os.environ}
  env.update(PATH=str(root/'bin')+':'+env['PATH'],XDG_CONFIG_HOME=str(here/'config'),
    XDG_STATE_HOME=str(here/'state'),XDG_CACHE_HOME=str(here/'cache'),
    CLOUDSDK_CORE_PROJECT='fixture-project',NAGARE_PLATFORM_ROOT=platform_root,
    NAGARE_INVENTORY_GCS_TRANSPORT='gcloud',PROBE_CASE=case,PROBE_TRACE=str(here/'trace.jsonl'))
  args=['inventory','store','status','--json'] if command=='status' else ['platform','bootstrap','plan','--out',str(here/'review')]
  start=time.monotonic()
  with (here/'stdout').open('w') as out,(here/'stderr').open('w') as err:
   p=subprocess.Popen([cli,'--context','fresh']+args,env=env,cwd=here,stdout=out,stderr=err,start_new_session=True)
   try: code=p.wait(timeout=30)
   except subprocess.TimeoutExpired:
    os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=10);code=124
  trace=[json.loads(s) for s in (here/'trace.jsonl').read_text().splitlines()]
  assert all(a[:3] not in [['storage','buckets','create'],['storage','buckets','update']] for a in trace)
  assert all(a[:2]!=['services','enable'] for a in trace)
  item={'case':case,'command':command,'exit':code,'seconds':round(time.monotonic()-start,3),
    'bucketDescribeCalls':sum(a[:3]==['storage','buckets','describe'] for a in trace),
    'remoteObjectCalls':sum(a[:2]==['storage','objects'] for a in trace),
    'error':(here/'stderr').read_text().strip()}
  if code==0 and command=='plan':
   review=json.loads((here/'review/review.json').read_text())
   item['operations']=[o['operation']['resources'] for o in review['operations']]
  if command=='status' and code==0: item['status']=json.loads((here/'stdout').read_text())
  results.append(item);print(json.dumps(item),flush=True)
  (root/'results.json').write_text(json.dumps(results,indent=2)+'\n')
