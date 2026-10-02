#!/usr/bin/env python3
"""Exercise legacy web cleanup through public CLI with disposable history."""

import json
import os
from pathlib import Path
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[1]
PROJECT = REPO / "cli/nagarectl"
root = Path(tempfile.mkdtemp(prefix="mp23-web-cleanup-public-"))
store = root / "state/nagare/web-cleanup-fixture/inventory"
binary = subprocess.check_output(
    ["cabal", "list-bin", "exe:nagarectl", "--enable-tests"], cwd=PROJECT, text=True
).strip()
subprocess.run([
    "cabal", "exec", "--", "runghc", "-package=nagarectl", "-package=nagare-dsl",
    "-XGHC2024", "-XDeriveAnyClass", "-XDuplicateRecordFields", "-XOverloadedLabels",
    "-XOverloadedStrings", str(REPO / "scripts/fixtures/WebCleanupPublicFixture.hs"),
    str(store), str(root), str(REPO / "scripts/fixtures/web-cleanup-native.yaml"),
], cwd=PROJECT, check=True, timeout=90)
fixture = json.loads((root / "fixture.json").read_text())
native = {item["native"]["metadata"]["name"]: item
          for item in json.loads((root / "native.json").read_text())}
state = {name: {"present": True, "uid": name + "-uid", "version": "10",
                "digest": item["digest"]} for name, item in native.items()}
(root / "provider-state.json").write_text(json.dumps(state) + "\n")
(root / "provider-calls.jsonl").write_text("")
config = root / "config/nagare"
(config / "contexts").mkdir(parents=True)
(config / "contexts/web-cleanup-fixture.env").write_text(
    "CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=local\n"
    "NAGARE_INVENTORY_STORE=local\nNAGARE_PLATFORM_VERSION=0.4.0\n")
(config / "kubeconfigs").mkdir()
(config / "kubeconfigs/web-cleanup-fixture.yaml").write_text(
    "apiVersion: v1\nkind: Config\n")
bins = root / "bin"
bins.mkdir()
kubectl = bins / "kubectl"
kubectl.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(os.environ['MP23_WEB_ROOT'])
args=sys.argv[1:]
with (root/'provider-calls.jsonl').open('a') as out:
    out.write(json.dumps(args)+'\\n')
state=json.loads((root/'provider-state.json').read_text())
native={item['native']['metadata']['name']:item for item in
        json.loads((root/'native.json').read_text())}
if 'get' in args:
    i=args.index('get'); name=args[i+2]
    entry=state.get(name)
    if entry and entry['present']:
        item=native[name]; obj=item['native']
        obj['metadata'].update({'uid':entry['uid'],'resourceVersion':entry['version'],
          'annotations':{'nagare.dev/context-id':'web-cleanup-fixture',
            'nagare.dev/resource-id':item['resource'],
            'nagare.dev/spec-digest':entry['digest']},
          'managedFields':[{'manager':'nagare-inventory','fieldsV1':{'f:data':{}}}]})
        if obj['kind']=='DomainMapping':
            obj['status']={'conditions':[{'type':'Ready','status':'True'}]}
        print(json.dumps(obj))
    sys.exit(0)
if 'apply' in args:
    obj=json.load(sys.stdin); name=obj['metadata']['name']
    assert name=='web-history',obj
    entry=state[name]
    assert entry['present'] and obj['metadata']['uid']==entry['uid'],obj
    assert obj['metadata']['resourceVersion']==entry['version'],obj
    entry['version']='11'
    entry['digest']=obj['metadata']['annotations']['nagare.dev/spec-digest']
    (root/'provider-state.json').write_text(json.dumps(state)+'\\n')
    print(json.dumps(obj)); sys.exit(0)
if 'delete' in args and '--raw' in args:
    path=args[args.index('--raw')+1]
    name=path.rsplit('/',1)[-1]
    body=json.load(sys.stdin); entry=state[name]
    assert entry['present'] and body['preconditions']=={
      'uid':entry['uid'],'resourceVersion':entry['version']},body
    entry['present']=False
    (root/'provider-state.json').write_text(json.dumps(state)+'\\n')
    print('{}'); sys.exit(0)
if 'wait' in args and '--for=delete' in args:
    name=next(part.split('/',1)[1] for part in args if '/' in part and
              part.split('/',1)[0] in ('service','configmap','domainmapping.serving.knative.dev'))
    assert not state[name]['present']; print('deleted'); sys.exit(0)
print('unexpected kubectl command',args,file=sys.stderr); sys.exit(95)
''')
kubectl.chmod(0o700)
env = {key: value for key, value in os.environ.items()
       if not key.startswith(("NAGARE_", "CLOUDSDK_", "PULUMI_", "DIRENV_", "GOOGLE_"))
       and key not in ("KUBECONFIG", "XDG_CONFIG_HOME", "XDG_STATE_HOME")}
env.update(HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"),
           XDG_STATE_HOME=str(root / "state"), NAGARE_PLATFORM_ROOT=str(REPO),
           PATH=str(bins) + os.pathsep + env["PATH"], MP23_WEB_ROOT=str(root))


def head():
    return json.loads((store / "head.json").read_text())


def data_revision():
    return next(item["revision"] for item in head()["accepted"]
                if item["scope"]["name"] == "web-cleanup-data")


def run(*args, expect=0):
    before = len((root / "provider-calls.jsonl").read_text().splitlines())
    result = subprocess.run([binary, "--context", "web-cleanup-fixture", *args],
                            cwd=root, env=env, capture_output=True, text=True, timeout=30)
    calls = [json.loads(line) for line in
             (root / "provider-calls.jsonl").read_text().splitlines()[before:]]
    print(json.dumps({"command": args, "exit": result.returncode,
                      "message": (result.stderr.strip() or result.stdout.strip())[-250:],
                      "providerCalls": len(calls)}), flush=True)
    assert result.returncode == expect, result.stderr
    return calls


original_data = data_revision()
original_data_state = {name: state[name] for name in
                       ("pg-main", "pg-main-data", "pg-main-backup")}
run("inventory", "compile", "--input", str(root / "candidate-input.json"),
    "--out", str(root / "candidate"))
run("inventory", "plan", "--inventory", str(root / "candidate"),
    "--out", str(root / "update-review"))
update_review = json.loads((root / "update-review/review.json").read_text())
assert [(operation["operation"]["action"]["tag"],
         operation["operation"]["resources"]) for operation in
        update_review["operations"]] == [("UpdateResource", [fixture["history"]])]
assert data_revision() == original_data
update_calls = run("inventory", "apply", str(root / "update-review"), "--yes")
assert len([c for c in update_calls if "apply" in c]) == 1
assert data_revision() == original_data
assert head()["activeTransaction"] is None
run("inventory", "retire", "--scope", "application:web-cleanup",
    "--out", str(root / "retire-review"))
assert json.loads((root / "retire-review/review.json").read_text())["operations"] == []
retire_calls = run("inventory", "apply", str(root / "retire-review"), "--yes")
assert not any("apply" in c or "delete" in c for c in retire_calls)
assert data_revision() == original_data
before_refusal = (store / "head.json").read_bytes()
run("inventory", "collect", "--resource", fixture["service"],
    "--out", str(root / "premature-review"), expect=1)
assert (store / "head.json").read_bytes() == before_refusal
for resource, name in [(fixture["history"], "web-history"),
                       (fixture["route"], "web.example.test"),
                       (fixture["service"], "web")]:
    review = root / (name + "-review")
    run("inventory", "collect", "--resource", resource, "--out", str(review))
    calls = run("inventory", "apply", str(review), "--yes")
    assert len([c for c in calls if "delete" in c]) == 1
    assert not json.loads((root / "provider-state.json").read_text())[name]["present"]
    assert data_revision() == original_data
    if name == "web-history":
        before_refusal = (store / "head.json").read_bytes()
        run("inventory", "collect", "--resource", fixture["service"],
            "--out", str(root / "still-premature-review"), expect=1)
        assert (store / "head.json").read_bytes() == before_refusal
collected = head()["collected"]
assert {item["resource"] for item in collected} == {
    fixture["service"], fixture["history"], fixture["route"]}
assert {item["tombstone"]["physical"] for item in collected} == {
    "web-uid", "web-history-uid", "web.example.test-uid"}
assert head()["activeTransaction"] is None and head()["accepted"] == head()["converged"]
final_state = json.loads((root / "provider-state.json").read_text())
assert {name: final_state[name] for name in original_data_state} == original_data_state
print("PASS: public legacy web policy update, effect-free retirement, guarded collection, data preservation")
print("Artifacts:", root)
