#!/usr/bin/env python3
"""Exercise legacy web cleanup through public CLI with disposable history."""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[1]
PROJECT = REPO / "cli/nagarectl"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--nagarectl", type=Path, help="installed executable to verify")
parser.add_argument("--partial", action="store_true", help="preserve data siblings in the same application scope")
parser.add_argument("--retain-data", action="store_true", help="retire the whole application while retaining its data siblings")
parser.add_argument("--knative", action="store_true", help="require reviewed Knative Service collection to cascade controller dependents")
parser.add_argument("--expect-orphan-block", action="store_true", help="reproduce the pending Knative orphan finalizer and original transaction")
options = parser.parse_args()
assert not options.expect_orphan_block or options.knative
assert not (options.partial and options.retain_data)
root = Path(tempfile.mkdtemp(prefix="mp23-web-cleanup-public-"))
store = root / "state/nagare/web-cleanup-fixture/inventory"
binary = str(options.nagarectl.absolute()) if options.nagarectl else subprocess.check_output(
    ["cabal", "list-bin", "exe:nagarectl", "--enable-tests"], cwd=PROJECT, text=True
).strip()
subprocess.run([
    "cabal", "exec", "--", "runghc", "-package=nagarectl", "-package=nagare-dsl",
    "-XGHC2024", "-XDeriveAnyClass", "-XDuplicateRecordFields", "-XOverloadedLabels",
    "-XOverloadedStrings", str(REPO / "scripts/fixtures/WebCleanupPublicFixture.hs"),
    str(store), str(root), str(REPO / ("scripts/fixtures/knative-web-cleanup-native.yaml" if options.knative else "scripts/fixtures/web-cleanup-native.yaml")),
    ("knative-" if options.knative else "") + ("partial" if options.partial else "retain-data" if options.retain_data else "whole"),
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
        if entry.get('terminating'):
            obj['metadata'].update({'deletionTimestamp':'2026-10-02T13:43:26Z','finalizers':['orphan']})
        if obj['kind']=='Service' and obj['apiVersion'].startswith('serving.knative.dev/'):
            obj['metadata']['generation']=1
            obj['status']={'observedGeneration':1,'conditions':[{'type':'Ready','status':'True'}]}
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
    obj=native[name]['native']
    if obj['kind']=='Service' and obj['apiVersion'].startswith('serving.knative.dev/'):
        assert body['propagationPolicy']==('Orphan' if os.environ['MP23_EXPECT_ORPHAN_BLOCK']=='1' else 'Background'), 'Knative webhook refuses orphaned Route/Configuration dependents'
    else:
        assert body['propagationPolicy']=='Orphan',body
    assert entry['present'] and body['preconditions']=={
      'uid':entry['uid'],'resourceVersion':entry['version']},body
    if obj['kind']=='Service' and obj['apiVersion'].startswith('serving.knative.dev/') and os.environ['MP23_EXPECT_ORPHAN_BLOCK']=='1':
        entry['terminating']=True
    else:
        entry['present']=False
    (root/'provider-state.json').write_text(json.dumps(state)+'\\n')
    print('{}'); sys.exit(0)
if 'wait' in args and '--for=delete' in args:
    name=next(part.split('/',1)[1] for part in args if '/' in part and
              part.split('/',1)[0] in ('service','service.serving.knative.dev','configmap','domainmapping.serving.knative.dev'))
    assert not state[name]['present']; print('deleted'); sys.exit(0)
print('unexpected kubectl command',args,file=sys.stderr); sys.exit(95)
''')
kubectl.chmod(0o700)
env = {key: value for key, value in os.environ.items()
       if not key.startswith(("NAGARE_", "CLOUDSDK_", "PULUMI_", "DIRENV_", "GOOGLE_"))
       and key not in ("KUBECONFIG", "XDG_CONFIG_HOME", "XDG_STATE_HOME")}
env.update(HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"),
           XDG_STATE_HOME=str(root / "state"), NAGARE_PLATFORM_ROOT=str(REPO),
           PATH=str(bins) + os.pathsep + env["PATH"], MP23_WEB_ROOT=str(root),
           MP23_EXPECT_ORPHAN_BLOCK='1' if options.expect_orphan_block else '0')


def head():
    return json.loads((store / "head.json").read_text())


def data_revision():
    selected = next((item["revision"] for item in head()["accepted"]
                     if item["scope"]["name"] == ("web-cleanup" if options.partial or options.retain_data else "web-cleanup-data")), None)
    if not (options.partial or options.retain_data):
        assert selected is not None
        return selected
    scope = json.loads((root / "initial-data-scope.json").read_text())
    identifiers = {fixture["webScope"] + "/database/" + suffix
                   for suffix in ("statefulset", "pvc", "backup-job")}
    members = lambda value: [d for b in value["bundles"] for d in b["declarations"]
                            if d["tag"] == "Managed" and d["contents"]["identity"] in identifiers]
    if selected is None:
        assert options.retain_data
        retained = {x["resource"]: x["incarnation"] for x in head()["retained"]}
        assert identifiers.issubset(retained)
        assert {retained[x]["physical"] for x in identifiers} == {"pg-main-uid", "pg-main-data-uid", "pg-main-backup-uid"}
        revisions = {retained[x]["revision"]["digest"] for x in identifiers}
        assert len(revisions) == 1
        selected = {"digest": revisions.pop()}
    current = next(json.loads(p.read_text()) for p in (store / "scopes").glob("*.json")
                   if p.stem == selected["digest"])
    assert members(current) == members(scope)
    return members(current)


results = []


def run(*args, expect=0):
    before = len((root / "provider-calls.jsonl").read_text().splitlines())
    result = subprocess.run([binary, "--context", "web-cleanup-fixture", *args],
                            cwd=root, env=env, capture_output=True, text=True, timeout=30)
    calls = [json.loads(line) for line in
             (root / "provider-calls.jsonl").read_text().splitlines()[before:]]
    print(json.dumps({"command": args, "exit": result.returncode,
                      "message": (result.stderr.strip() or result.stdout.strip())[-250:],
                      "providerCalls": len(calls)}), flush=True)
    results.append({"command": args, "exit": result.returncode,
                    "stdout": result.stdout, "stderr": result.stderr,
                    "providerCalls": calls})
    assert result.returncode == expect, result.stderr
    return calls


if options.partial or options.retain_data:
    initial = next(x["declaration"] for x in json.loads((root / "candidate-input.json").read_text())["snapshot"] if x["declaration"]["scope"]["name"] == "web-cleanup")
    (root / "initial-data-scope.json").write_text(json.dumps(initial) + "\n")
original_data = data_revision()
original_neighbor = next(x for x in head()["accepted"] if x["scope"]["name"] == "cluster")
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
if options.partial:
    current = head()
    app_revision = next(x["revision"] for x in current["accepted"] if x["scope"]["name"] == "web-cleanup")
    declared = json.loads((store / "scopes" / (app_revision["digest"] + ".json")).read_text())
    remaining = copy.deepcopy(declared)
    removed = {fixture[key] for key in ("service", "history", "route")}
    for bundle in remaining["bundles"]:
        bundle["declarations"] = [d for d in bundle["declarations"]
                                  if d["tag"] != "Managed" or d["contents"]["identity"] not in removed]
    candidate = {"version": 1, "context": current["binding"],
                 "base": [{"scope": x["scope"], "generation": x["revision"]["generation"]}
                          for x in current["accepted"]],
                 "snapshot": [{"generation": x["revision"]["generation"],
                               "declaration": json.loads((store / "scopes" / (x["revision"]["digest"] + ".json")).read_text())}
                              for x in current["accepted"]],
                 "reservations": [], "changes": [{"replace": remaining}]}
    (root / "partial-input.json").write_text(json.dumps(candidate) + "\n")
    run("inventory", "compile", "--input", str(root / "partial-input.json"), "--out", str(root / "partial-candidate"))
    run("inventory", "plan", "--inventory", str(root / "partial-candidate"),
        *[arg for key in ("service", "history", "route") for arg in ("--retain-resource", fixture[key])],
        "--out", str(root / "retire-review"))
else:
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
    if options.expect_orphan_block and name == "web":
        calls = run("inventory", "apply", str(review), "--yes", expect=1)
        assert head()["activeTransaction"] == "tx-" + (review / "review.sha256").read_text().strip()
        provider = json.loads((root / "provider-state.json").read_text())[name]
        assert provider["present"] and provider["terminating"] and provider["uid"] == "web-uid"
        assert len([c for c in calls if "delete" in c]) == 1
        retained = next(x for x in head()["retained"] if x["resource"] == fixture["service"])
        assert retained["incarnation"]["physical"] == "web-uid"
        assert data_revision() == original_data
        break
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
expected_collected = {fixture["history"], fixture["route"]}
expected_uids = {"web-history-uid", "web.example.test-uid"}
if not options.expect_orphan_block:
    expected_collected.add(fixture["service"])
    expected_uids.add("web-uid")
    assert head()["activeTransaction"] is None
assert {item["resource"] for item in collected} == expected_collected
assert {item["tombstone"]["physical"] for item in collected} == expected_uids
assert head()["accepted"] == head()["converged"]
assert next(x for x in head()["accepted"] if x["scope"]["name"] == "cluster") == original_neighbor
final_state = json.loads((root / "provider-state.json").read_text())
assert {name: final_state[name] for name in original_data_state} == original_data_state
identity = ({"installedVersion": json.loads(subprocess.check_output(
    [binary, "version", "--json"], env=env, text=True, timeout=15))}
    if options.nagarectl else {"binarySha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest()})
(root / "result.json").write_text(json.dumps({
    "mode": "partial" if options.partial else "retain-data" if options.retain_data else "whole",
    "knative": options.knative,
    **identity, "results": results, "finalHead": head(),
    "dataDeclarationsAndIdentitiesPreserved": True, "neighborRevisionPreserved": True,
    "orphanCollectionBlocked": options.expect_orphan_block, "cleanupComplete": not options.expect_orphan_block}, indent=2) + "\n")
print("PASS: public pending Knative collection preserves the original transaction and data" if options.expect_orphan_block else "PASS: public legacy web policy update, effect-free retirement, guarded collection, data preservation")
print("Artifacts:", root)
