#!/usr/bin/env python3
"""Verify public CDN-disable planning preserves a composed namespace contribution.

Providers are strict read-only recorders. The typed inventory, accepted history,
native document loading, composition, observations and review are real CLI code.
"""

import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[1]
PROJECT = REPO / "cli/nagarectl"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--nagarectl", type=Path, help="executable to verify")
options = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="mp23-cdn-disable-public-"))
print(f"Artifacts: {root}", flush=True)
store = root / "state/nagare/cdn-disable-fixture/inventory"
binary = str(options.nagarectl.absolute()) if options.nagarectl else subprocess.check_output(
    ["cabal", "list-bin", "exe:nagarectl", "--enable-tests"], cwd=PROJECT, text=True
).strip()
subprocess.run([
    "cabal", "exec", "--", "runghc", "-package=nagarectl", "-package=nagare-dsl",
    "-XGHC2024", "-XDeriveAnyClass", "-XDuplicateRecordFields", "-XOverloadedLabels",
    "-XOverloadedStrings", str(REPO / "scripts/fixtures/CdnDisablePublicFixture.hs"),
    str(store), str(root),
], cwd=PROJECT, check=True, timeout=90)
initial_head = (store / "head.json").read_bytes()
initial_scopes = {p.name: p.read_bytes() for p in (store / "scopes").glob("*.json")}
payload = root / "payload"
for relative in [
    "release.json", "cli/nagare-dsl/nagare-dsl.cabal", "cli/nagare-access/nagare-access.cabal",
    "cli/nagare-access/Dockerfile", "infra/pulumi/Pulumi.yaml", "cluster/bootstrap/render-context-template.sh",
    "nixos/flake.nix", "scripts/lib/target.sh", "justfile", "docs/user/reference.md",
    "docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md",
    "docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md",
]:
    path = payload / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("offline fixture\n")
(payload / "release.json").write_bytes((REPO / "release.json").read_bytes())
for relative in ["cluster/examples", "cluster/observability", "cluster/local", "docs/runbooks"]:
    (payload / relative).mkdir(parents=True, exist_ok=True)
config = root / "config/nagare"
(config / "contexts").mkdir(parents=True)
(config / "contexts/cdn-disable-fixture.env").write_text(
    "CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=local\n"
    "NAGARE_INVENTORY_STORE=local\nNAGARE_PLATFORM_VERSION=0.4.0\nNAGARE_BASE_DOMAIN=example.test\n")
(config / "kubeconfigs").mkdir()
(config / "kubeconfigs/cdn-disable-fixture.yaml").write_text("apiVersion: v1\nkind: Config\n")
adc = root / "fixture-adc.json"
adc.write_text(json.dumps({"type": "authorized_user", "quota_project_id": "project",
                           "account": "fixture@example.test"}))
calls = root / "provider-calls.jsonl"
calls.write_text("")
bins = root / "bin"
bins.mkdir()
recorder = r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(os.environ['MP23_CDN_ROOT'])
tool=Path(sys.argv[0]).name
args=sys.argv[1:]
with (root/'provider-calls.jsonl').open('a') as out:
    out.write(json.dumps([tool,*args])+'\n')
if tool=='gcloud':
    if args==['auth','list','--filter=status:ACTIVE','--format=value(account)']:
        print('fixture@example.test');sys.exit(0)
    if args==['config','get-value','project']:
        print('project');sys.exit(0)
    if args[:3]==['dns','record-sets','list'] and len(args)==8 and args[3] in ['--name=www.example.test.','--name=example.test.'] and args[4:]==['--type=A','--zone=zone','--format=json','--project=project']:
        print(json.dumps([{'name':args[3].split('=',1)[1],'type':'A','ttl':300,'rrdatas':['203.0.113.4']}]));sys.exit(0)
if tool=='pulumi' and args[:1]==['-C']:
    operation=args[2:]
    if operation==['stack','select','cdn-disable-fixture']:
        sys.exit(0)
    if operation==['config','--json','--stack','cdn-disable-fixture','--non-interactive']:
        print(json.dumps({'gcp:project':{'value':'project'}}));sys.exit(0)
    if operation[:2]==['stack','output'] and len(operation)==3:
        outputs={'publicIp':'203.0.113.9','cdnGlobalIp':'203.0.113.4','cdnBackendService':'backend','cdnUrlMap':'url-map','dnsZoneName':'zone'}
        if operation[2] in outputs:
            print(outputs[operation[2]]);sys.exit(0)
if tool=='kubectl' and 'get' in args:
    i=args.index('get'); name=args[i+2]
    for item in json.loads((root/'native.json').read_text()):
        obj=item['native'];meta=obj['metadata']
        if meta['name']!=name:continue
        meta.update(uid=name+'-uid',resourceVersion='10',generation=1)
        meta.setdefault('annotations',{}).update({
            'nagare.dev/context-id':'cdn-disable-fixture',
            'nagare.dev/resource-id':item['resource'],
            'nagare.dev/spec-digest':item['digest']})
        obj['status']={'observedGeneration':1,'conditions':[{'type':'Ready','status':'True'}]}
        print(json.dumps(obj));sys.exit(0)
with (root/'unexpected-calls.jsonl').open('a') as out:
    out.write(json.dumps([tool,*args])+'\n')
print('unexpected provider command refused: '+tool+' '+str(args),file=sys.stderr)
sys.exit(95)
'''
for tool in ["kubectl", "gcloud", "pulumi", "helm", "nix", "ssh", "docker", "k3d", "curl", "aws", "mc", "npm"]:
    path = bins / tool
    path.write_text(recorder)
    path.chmod(0o700)
env = {k: v for k, v in os.environ.items()
       if not k.startswith(("NAGARE_", "CLOUDSDK_", "PULUMI_", "DIRENV_", "GOOGLE_"))
       and k not in ("KUBECONFIG", "XDG_CONFIG_HOME", "XDG_STATE_HOME")}
env.update(HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"),
           XDG_STATE_HOME=str(root / "state"), NAGARE_PLATFORM_ROOT=str(payload),
           GOOGLE_APPLICATION_CREDENTIALS=str(adc), MP23_CDN_ROOT=str(root),
           PATH=str(bins) + os.pathsep + env["PATH"])
results = []
for host, directory, expected_exit in [("www.example.test", "review", 0), ("unowned.example.test", "unowned-review", 1)]:
    result = subprocess.run([binary, "--context", "cdn-disable-fixture", "cdn", "disable", host,
                             "--save-plan", str(root / directory)], cwd=root, env=env,
                            text=True, capture_output=True, timeout=30)
    results.append({"host": host, "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
    (root / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results[-1]), flush=True)
    assert result.returncode == expected_exit, result.stderr
    assert (store / "head.json").read_bytes() == initial_head
    assert all((store / "scopes" / name).read_bytes() == content
               for name, content in initial_scopes.items())
review = json.loads((root / "review/review.json").read_text())
operations = [item["operation"] for item in review["operations"]]
assert len(operations) == 1, operations
assert operations[0]["action"]["tag"] == "UpdateResource", operations
assert operations[0]["resources"] == ["application:demo/www.example.test/dns-a"], operations
before = json.loads(initial_head)
original_app = next(item for item in before["accepted"] if item["scope"]["kind"] == "Application")
desired_app = next(item for item in review["desiredRevisions"] if item["scope"]["kind"] == "Application")
expected_scope = copy.deepcopy(json.loads(initial_scopes[original_app["revision"]["digest"] + ".json"]))
for bundle in expected_scope["bundles"]:
    for declaration in bundle["declarations"]:
        if declaration["tag"] == "Managed" and declaration["contents"]["identity"] == operations[0]["resources"][0]:
            declaration["contents"]["spec"] = {"tag": "DnsARecord", "contents": ["203.0.113.9", 300]}
assert json.loads((store / "scopes" / (desired_app["revision"]["digest"] + ".json")).read_text()) == expected_scope
assert [item for item in review["desiredRevisions"] if item["scope"]["kind"] == "Platform"] == [
    item for item in before["accepted"] if item["scope"]["kind"] == "Platform"]
provider_calls = [json.loads(line) for line in calls.read_text().splitlines()]
assert any(call[0] == "kubectl" and "demo-namespace" in call for call in provider_calls), provider_calls
assert not (root / "unowned-review").exists()
assert not (root / "unexpected-calls.jsonl").exists()
print("Public CDN-disable contribution regression passed: one DNS update, generated namespace observed, accepted history unchanged, unowned host refused.")
