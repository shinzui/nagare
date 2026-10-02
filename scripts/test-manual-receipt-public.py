#!/usr/bin/env python3
"""Exercise manual receipt review, collection, and restore through the public CLI.

The fixture uses a disposable accepted filesystem history and recording provider
shims. No cluster, object store, or cloud project is contacted.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


REPO = Path(__file__).resolve().parents[1]
PROJECT = REPO / "cli/nagarectl"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--gcs", action="store_true")
parser.add_argument("--nagarectl", type=Path, help="installed executable to verify")
options = parser.parse_args()
MODE = "gcs" if options.gcs else "local"
root = Path(tempfile.mkdtemp(prefix="mp23-manual-receipt-public-"))
store = root / "state/nagare/manual-receipt-fixture/inventory"
binary = str(options.nagarectl.absolute()) if options.nagarectl else subprocess.check_output(
    ["cabal", "list-bin", "exe:nagarectl", "--enable-tests"],
    cwd=PROJECT,
    text=True,
).strip()
subprocess.run(
    [
        "cabal", "exec", "--", "runghc", "-package=nagarectl",
        "-package=nagare-dsl", "-XGHC2024", "-XDeriveAnyClass",
        "-XDuplicateRecordFields", "-XOverloadedLabels", "-XOverloadedStrings",
        str(REPO / "scripts/fixtures/ManualReceiptPublicFixture.hs"),
        str(store), str(root), MODE,
    ],
    cwd=PROJECT,
    check=True,
    timeout=90,
)
fixture = json.loads((root / "fixture.json").read_text())
(root / "provider-state.json").write_text(json.dumps({
    "jobPresent": True,
    "jobUid": "backup-job-uid",
    "receiptVersion": "12" if MODE == "gcs" else "receipt-v1",
    "archiveVersion": "11" if MODE == "gcs" else "archive-v1",
    "restoreJobPresent": False,
}) + "\n")
(root / "provider-calls.jsonl").write_text("")

config = root / "config/nagare"
(config / "contexts").mkdir(parents=True)
(config / "kubeconfigs").mkdir()
(config / "contexts/manual-receipt-fixture.env").write_text(
    "CLOUDSDK_CORE_PROJECT=project\n"
    f"NAGARE_MODE={'cloud' if MODE == 'gcs' else 'local'}\n"
    "NAGARE_INVENTORY_STORE=local\n"
    "NAGARE_PLATFORM_VERSION=0.4.0\n"
    "NAGARE_BACKUP_BUCKET=bucket\n"
    "NAGARE_LOCAL_OBJECT_STORE=http://minio.nagare-system.svc.cluster.local:9000/bucket\n"
)
(config / "hosts/manual-receipt-fixture").mkdir(parents=True)
(config / "hosts/manual-receipt-fixture/host.nix").write_text('hostName = "fixture-node";\n')
(config / "kubeconfigs/manual-receipt-fixture.yaml").write_text(
    "apiVersion: v1\nkind: Config\n"
)
bins = root / "bin"
bins.mkdir()
kubectl = bins / "kubectl"
kubectl.write_text('''#!/usr/bin/env python3
import base64,json,os,signal,subprocess,sys,time
from pathlib import Path
root=Path(os.environ['MP23_MANUAL_ROOT'])
args=sys.argv[1:]
with (root/'provider-calls.jsonl').open('a') as out:
    out.write(json.dumps(['kubectl',*args])+'\\n')
if 'port-forward' in args:
    print('Forwarding from 127.0.0.1:19000 -> 9000',flush=True)
    while True: time.sleep(1)
if args[:2]==['config','current-context']:
    print('manual-receipt-fixture')
    sys.exit(0)
if 'get' in args and args[args.index('get')+1]=='nodes':
    print(json.dumps({'items':[{'metadata':{'name':'fixture-node','labels':
      {'node-role.kubernetes.io/control-plane':''}}}]}))
    sys.exit(0)
if 'delete' in args and '--raw' in args:
    body=json.load(sys.stdin)
    assert body['preconditions']['uid']=='backup-job-uid',body
    state=json.loads((root/'provider-state.json').read_text())
    assert state['jobPresent'],state
    state['jobPresent']=False
    (root/'provider-state.json').write_text(json.dumps(state)+'\\n')
    print('{}')
    sys.exit(0)
if 'create' in args and '-f' in args:
    obj=json.load(sys.stdin)
    assert obj['kind']=='Job' and obj['metadata']['name']=='nagare-dbrestore-pg-main-receipt-r1',obj
    state=json.loads((root/'provider-state.json').read_text())
    assert not state['restoreJobPresent'],state
    state['restoreJobPresent']=True
    (root/'provider-state.json').write_text(json.dumps(state)+'\\n')
    (root/'restore-job.json').write_text(json.dumps(obj)+'\\n')
    if os.environ['MP23_MANUAL_MODE']=='gcs':
        download=next(c for c in obj['spec']['template']['spec']['initContainers'] if c['name']=='download')
        selected={e['name']:e['value'] for e in download['env'] if 'value' in e}
        assert selected.get('OBJECT_VERSION')==state['archiveVersion'],selected
        assert selected.get('RECEIPT_VERSION')==state['receiptVersion'],selected
        dump=root/'executed-download'; dump.mkdir()
        command=download['args'][0].replace('/dump/',str(dump)+'/')
        subprocess.run([*download['command'],command],env={**os.environ,**selected},check=True,timeout=10)
        assert (dump/'backup.sql').read_bytes()==b'CREATE TABLE restored (id integer);\\n'
        (root/'download-executed.json').write_text(json.dumps({'objectVersion':selected['OBJECT_VERSION'],
          'receiptVersion':selected['RECEIPT_VERSION'],'sqlVerified':True})+'\\n')
    print(json.dumps(obj))
    sys.exit(0)
if 'wait' in args and '--for=delete' in args:
    assert not json.loads((root/'provider-state.json').read_text())['jobPresent']
    print('job deleted')
    sys.exit(0)
if 'wait' in args and '--for=condition=complete' in args:
    assert json.loads((root/'provider-state.json').read_text())['restoreJobPresent']
    print('job completed')
    sys.exit(0)
if 'get' not in args:
    print('unexpected kubectl mutation',file=sys.stderr)
    sys.exit(95)
i=args.index('get')
kind=args[i+1]
name=args[i+2] if i+2<len(args) and not args[i+2].startswith('-') else ''
if kind=='secret' and name and 'nagare-system' in args:
    data={key:base64.b64encode(value.encode()).decode() for key,value in
          {'AWS_ACCESS_KEY_ID':'fixture-access','AWS_SECRET_ACCESS_KEY':'fixture-secret'}.items()}
    print(json.dumps({'data':data}))
    sys.exit(0)
if kind=='pods':
    message=(root/'receipt.json').read_text()
    print(json.dumps({'items':[{'metadata':{'ownerReferences':[{'kind':'Job','uid':'backup-job-uid','controller':True}]},
      'status':{'phase':'Succeeded','containerStatuses':[{'name':'upload','state':{'terminated':
        {'exitCode':0,'message':message}}}]}}]}))
    sys.exit(0)
aliases={'jobs':'Job','job':'Job','job.batch':'Job','statefulset':'StatefulSet',
  'statefulset.apps':'StatefulSet','persistentvolumeclaim':'PersistentVolumeClaim',
  'pvc':'PersistentVolumeClaim','secret':'Secret','service':'Service','cronjob':'CronJob',
  'serviceaccount':'ServiceAccount','role':'Role','rolebinding':'RoleBinding'}
target=aliases.get(kind.lower(),kind)
if target=='Job' and name=='nagare-dbrestore-pg-main-receipt-r1':
    if not json.loads((root/'provider-state.json').read_text())['restoreJobPresent']:
        sys.exit(0)
    obj=json.loads((root/'restore-job.json').read_text())
    obj['metadata']['uid']='restore-job-uid'
    obj['metadata']['resourceVersion']='11'
    obj['status']={'conditions':[{'type':'Complete','status':'True'}],'succeeded':1}
    print(json.dumps(obj))
    sys.exit(0)
if target=='Job' and not json.loads((root/'provider-state.json').read_text())['jobPresent']:
    sys.exit(0)
for item in json.loads((root/'native.json').read_text()):
    obj=item['native']
    if obj.get('kind')==target and obj.get('metadata',{}).get('name')==name:
        obj['metadata'].setdefault('annotations',{}).update({
          'nagare.dev/context-id':'manual-receipt-fixture',
          'nagare.dev/resource-id':item['resource'],
          'nagare.dev/spec-digest':item['digest']})
        obj['metadata']['uid']={'Job':json.loads((root/'provider-state.json').read_text())['jobUid'],
          'StatefulSet':'stateful-uid',
          'PersistentVolumeClaim':'pvc-uid'}.get(target,target.lower()+'-uid')
        obj['metadata']['resourceVersion']='10'
        obj['metadata']['generation']=1
        if target=='Job': obj['status']={'conditions':[{'type':'Complete','status':'True'}],
          'succeeded':1}
        if target=='StatefulSet': obj['status']={'observedGeneration':1,
          'readyReplicas':1,'updatedReplicas':1}
        print(json.dumps(obj))
        sys.exit(0)
sys.exit(0)
''')
kubectl.chmod(0o700)
curl = bins / "curl"
curl.write_text('''#!/usr/bin/env python3
import json,os,shutil,sys
from pathlib import Path
root=Path(os.environ['MP23_MANUAL_ROOT'])
args=sys.argv[1:]
with (root/'provider-calls.jsonl').open('a') as out:
    out.write(json.dumps(['curl',*args])+'\\n')
url=args[-1]
output=Path(args[args.index('--output')+1])
headers=Path(args[args.index('--dump-header')+1])
fixture=json.loads((root/'fixture.json').read_text())
state=json.loads((root/'provider-state.json').read_text())
if url.endswith(fixture['backupReceipt'].replace('s3://','http://127.0.0.1:19000/')):
    source=root/'receipt.json'; version=state['receiptVersion']
elif url.endswith(fixture['backupObject'].replace('s3://','http://127.0.0.1:19000/')):
    source=root/'archive'; version=state['archiveVersion']
else:
    print('unexpected object address',url,file=sys.stderr); sys.exit(95)
shutil.copyfile(source,output)
headers.write_text('HTTP/1.1 200 OK\\r\\nx-amz-version-id: '+version+
  '\\r\\ncontent-length: '+str(source.stat().st_size)+'\\r\\n\\r\\n')
''')
curl.chmod(0o700)
gcloud = bins / "gcloud"
gcloud.write_text('''#!/usr/bin/env python3
import json,os,shutil,sys
from pathlib import Path
root=Path(os.environ['MP23_MANUAL_ROOT'])
args=sys.argv[1:]
with (root/'provider-calls.jsonl').open('a') as out:
    out.write(json.dumps(['gcloud',*args])+'\\n')
fixture=json.loads((root/'fixture.json').read_text())
state=json.loads((root/'provider-state.json').read_text())
if 'describe' in args:
    url=args[args.index('describe')+1]
    if url==fixture['backupReceipt']:
        source=root/'receipt.json'; version=state['receiptVersion']
    elif url==fixture['backupObject']:
        source=root/'archive'; version=state['archiveVersion']
    else:
        print('unexpected GCS describe',url,file=sys.stderr); sys.exit(95)
    print(json.dumps({'bucket':'bucket','name':url.removeprefix('gs://bucket/'),
      'generation':version,'size':str(source.stat().st_size)}))
    sys.exit(0)
if 'cp' in args:
    url=args[args.index('--do-not-decompress')+1]
    output=Path(args[-1])
    if url==fixture['backupReceipt']+'#'+state['receiptVersion']:
        source=root/'receipt.json'
    elif url==fixture['backupObject']+'#'+state['archiveVersion']:
        source=root/'archive'
    else:
        print('unexpected GCS generation',url,file=sys.stderr); sys.exit(95)
    shutil.copyfile(source,output)
    sys.exit(0)
print('unexpected gcloud command',args,file=sys.stderr)
sys.exit(95)
''')
gcloud.chmod(0o700)

env = {key: value for key, value in os.environ.items()
       if not key.startswith(("NAGARE_", "CLOUDSDK_", "PULUMI_", "DIRENV_", "GOOGLE_"))
       and key not in ("KUBECONFIG", "XDG_CONFIG_HOME", "XDG_STATE_HOME")}
env.update(
    HOME=str(root / "home"),
    XDG_CONFIG_HOME=str(root / "config"),
    XDG_STATE_HOME=str(root / "state"),
    NAGARE_PLATFORM_ROOT=str(REPO),
    PATH=str(bins) + os.pathsep + env["PATH"],
    MP23_MANUAL_ROOT=str(root),
    MP23_MANUAL_MODE=MODE,
)


results = []


def head():
    return json.loads((store / "head.json").read_text())


def revision(scope_name):
    return next(item["revision"] for item in head()["accepted"]
                if item["scope"]["name"] == scope_name)


def set_provider(**updates):
    path = root / "provider-state.json"
    state = json.loads(path.read_text())
    state.update(updates)
    path.write_text(json.dumps(state) + "\n")


def run(*arguments, expect=0):
    before = len((root / "provider-calls.jsonl").read_text().splitlines())
    started = time.monotonic()
    result = subprocess.run(
        [binary, "--context", "manual-receipt-fixture", *arguments],
        cwd=root, env=env, capture_output=True, text=True, timeout=30,
    )
    calls = [json.loads(line) for line in
             (root / "provider-calls.jsonl").read_text().splitlines()[before:]]
    record = {"command": arguments, "exit": result.returncode,
              "stdout": result.stdout, "stderr": result.stderr,
              "seconds": round(time.monotonic() - started, 3),
              "providerCalls": calls}
    results.append(record)
    print(json.dumps({"command": arguments, "exit": result.returncode,
                      "message": result.stderr.strip() or result.stdout.strip().splitlines()[-1],
                      "providerCalls": len(calls),
                      "seconds": record["seconds"]}), flush=True)
    assert result.returncode == expect, result.stderr
    return result, calls


original_database = revision("database-pg-main")
original_neighbor = revision("neighbor")
initial_head = (store / "head.json").read_bytes()
set_provider(jobUid="foreign-job-uid")
_, foreign_calls = run("db", "backup-receipt", "pg-main", "-n", "default",
    "--backup-id", "run-001", "--save-plan", str(root / "foreign-review"), expect=1)
assert not any(call[0] in ("curl", "gcloud") for call in foreign_calls)
assert (store / "head.json").read_bytes() == initial_head
assert not (root / "foreign-review").exists()
set_provider(jobUid="backup-job-uid")
receipt_review = root / "receipt-review"
run("db", "backup-receipt", "pg-main", "-n", "default", "--backup-id", "run-001",
    "--save-plan", str(receipt_review))
run("inventory", "apply", str(receipt_review), "--yes")
assert revision("database-pg-main") == original_database
assert revision("neighbor") == original_neighbor
collected_review = root / "collection-review"
run("inventory", "collect", "--resource", fixture["backupJob"], "--out",
    str(collected_review))
_, collection_calls = run("inventory", "apply", str(collected_review), "--yes")
deletes = [call for call in collection_calls if call[0] == "kubectl" and "delete" in call]
assert len(deletes) == 1 and "nagare-dbbackup-pg-main-run-001" in " ".join(deletes[0])
assert not json.loads((root / "provider-state.json").read_text())["jobPresent"]
assert revision("database-pg-main") == original_database
assert revision("neighbor") == original_neighbor
collected = head()["collected"]
assert len(collected) == 1 and collected[0]["resource"] == fixture["backupJob"]
assert collected[0]["tombstone"]["physical"] == "backup-job-uid"
after_collection = (store / "head.json").read_bytes()
set_provider(archiveVersion="13" if MODE == "gcs" else "archive-v2")
_, changed_calls = run("db", "restore", "pg-main", "run-001", "-n", "default",
    "--restore-id", "wrong-version", "--save-plan", str(root / "wrong-version-review"),
    expect=1)
assert not any(call[0] == "kubectl" and "delete" in call for call in changed_calls)
assert (store / "head.json").read_bytes() == after_collection
assert not (root / "wrong-version-review").exists()
set_provider(archiveVersion="11" if MODE == "gcs" else "archive-v1")
restore_review = root / "restore-review"
_, restore_calls = run("db", "restore", "pg-main", "run-001", "-n", "default", "--restore-id",
    "receipt-r1", "--save-plan", str(restore_review))
assert not any(call[0] == "kubectl" and
               ("nagare-dbbackup-pg-main-run-001" in " ".join(call) or "pods" in call)
               for call in restore_calls)
assert revision("database-pg-main") == original_database
assert revision("neighbor") == original_neighbor
assert (store / "head.json").read_bytes() == after_collection
assert restore_review.is_dir()
_, restore_apply_calls = run("inventory", "apply", str(restore_review), "--yes")
creates = [call for call in restore_apply_calls if call[0] == "kubectl" and "create" in call]
assert len(creates) == 1
assert not any(call[0] == "kubectl" and
               "nagare-dbbackup-pg-main-run-001" in " ".join(call)
               for call in restore_apply_calls)
assert json.loads((root / "provider-state.json").read_text())["restoreJobPresent"]
assert revision("database-pg-main") == original_database
assert revision("neighbor") == original_neighbor
assert head()["activeTransaction"] is None and head()["accepted"] == head()["converged"]
mutations = [call for result in results for call in result["providerCalls"]
             if call[0] == "kubectl" and any(verb in call for verb in
             ("create", "delete", "patch", "replace", "apply"))]
assert len(mutations) == 2 and "delete" in mutations[0] and "create" in mutations[1]
assert not any("pg-main" in " ".join(call) and "nagare-dbrestore" not in " ".join(call)
               and "nagare-dbbackup-pg-main-run-001" not in " ".join(call)
               for call in mutations)
if MODE == "gcs":
    assert json.loads((root / "download-executed.json").read_text())["sqlVerified"]
    assert not any(call[0] == "curl" for result in results
                   for call in result["providerCalls"])
    copies = [call for result in results for call in result["providerCalls"]
              if call[0] == "gcloud" and "cp" in call]
    assert copies and all("--do-not-decompress" in call for call in copies)
    assert all(any("#" in argument for argument in call) for call in copies)
else:
    assert not any(call[0] == "gcloud" for result in results
                   for call in result["providerCalls"])
binary_identity = (
    {"installedVersion": json.loads(subprocess.check_output(
        [binary, "version", "--json"], env=env, text=True, timeout=15))}
    if options.nagarectl else
    {"binarySha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest()}
)
(root / "result.json").write_text(json.dumps({"mode": MODE, "fixture": fixture,
    **binary_identity,
    "results": results,
    "finalHead": head()}, indent=2) + "\n")
print("PASS:", MODE, "public receipt review/apply, exact Job collection, and Job-free restore apply")
print("Artifacts:", root)
