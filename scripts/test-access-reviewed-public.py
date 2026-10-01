#!/usr/bin/env python3
"""Exercise saved access reviews and the common journal against bounded transports.

The typed seed comes from InventoryAccessSpec, not a handwritten inventory.
Pass the built nagarectl executable and test executable as positional arguments.
"""

import http.server
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading


def tuple_wire(host, user):
    return {"object": {"objectType": "app", "objectId": host}, "relation": "viewer",
            "subject": {"kind": "id", "objectType": "user", "objectId": user}, "caveat": None}


def main():
    cli, tests = map(lambda value: str(Path(value).resolve()), sys.argv[1:3])
    with tempfile.TemporaryDirectory(prefix="nagare-access-public-") as temporary:
        root = Path(temporary)
        env = {key: os.environ[key] for key in ("HOME", "USER", "PATH") if key in os.environ}
        env.update(MP23_ACCESS_FIXTURE_ROOT=str(root), XDG_CONFIG_HOME=str(root / "config"),
                   XDG_STATE_HOME=str(root / "state"), XDG_CACHE_HOME=str(root / "cache"),
                   NAGARE_EN_API_KEY="fixture-private-key", ACCESS_FIXTURE_ROOT=str(root))
        subprocess.run([tests, "-p", "seed complete public command fixture"], env=env, check=True,
                       cwd=Path(__file__).resolve().parent.parent / "cli/nagarectl",
                       stdout=subprocess.DEVNULL)
        config = root / "config/nagare"
        (config / "contexts").mkdir(parents=True)
        (config / "kubeconfigs").mkdir()
        (config / "contexts/access-test.env").write_text(
            "NAGARE_MODE=local\nCLOUDSDK_CORE_PROJECT=project\nNAGARE_INVENTORY_STORE=local\n"
            "NAGARE_PULUMI_BACKEND=local\nNAGARE_BASE_DOMAIN=example.test\n"
            "NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000\n"
            "NAGARE_LOCAL_OBJECT_STORE=http://minio.nagare-system.svc.cluster.local:9000/nagare-backups\n")
        (config / "kubeconfigs/access-test.yaml").write_text("fixture-only\n")
        (root / "bin").mkdir()
        for item in json.loads((root / "maps.json").read_text()):
            native = item["native"].encode()
            value = json.loads(native)
            metadata = value["metadata"]
            metadata.update(uid=metadata["name"] + "-uid", resourceVersion="1",
                            managedFields=[{"manager": "nagare-inventory", "fieldsV1": {"f:data": {}}}],
                            annotations={"nagare.dev/context-id": "access-test",
                                         "nagare.dev/resource-id": item["resource"],
                                         "nagare.dev/spec-digest": hashlib.sha256(native).hexdigest()})
            if value["kind"] == "Deployment":
                metadata["generation"] = 1
                value["status"] = {"observedGeneration": 1, "conditions": [{"type": "Available", "status": "True"}]}
            (root / (metadata["name"] + ".json")).write_text(json.dumps(value))
        kubectl = root / "bin/kubectl"
        kubectl.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
r=Path(os.environ['ACCESS_FIXTURE_ROOT'])
assert os.environ['KUBECONFIG']==str(r/'config/nagare/kubeconfigs/access-test.yaml')
a=[arg for arg in sys.argv[1:] if not arg.startswith('--request-timeout=')]
assert a[:2]==['--context','access-test'],a
a=a[2:]
if a[0]=='rollout':
 assert a==['rollout','status','deployment/shomei','--namespace','nagare-system','--timeout=300s'],a
 print('fixture rollout available');sys.exit(0)
if a[0]=='apply':
 assert '--server-side' in a,a
 value=json.loads(sys.stdin.read()); name=value['metadata']['name']; path=r/(name+'.json')
 prior=json.loads(path.read_text())
 assert value['metadata']['uid']==prior['metadata']['uid']
 assert value['metadata']['resourceVersion']==prior['metadata']['resourceVersion']
 assert name in ['nagare-shomei-settings','shomei'],name
 value['metadata']['resourceVersion']=str(int(prior['metadata']['resourceVersion'])+1)
 value['metadata']['managedFields']=prior['metadata']['managedFields']
 if name=='shomei':
  value['metadata']['generation']=prior['metadata']['generation']+1
  value['status']={'observedGeneration':value['metadata']['generation'],'conditions':[{'type':'Available','status':'True'}]}
 path.write_text(json.dumps(value))
 with (r/'map-writes').open('a') as log: log.write(name+'\\n')
 print(json.dumps(value));sys.exit(0)
assert a[0]=='get',a
kind,name=a[1:3]
if kind in ['configmap','deployment.apps']:
 value=json.loads((r/(name+'.json')).read_text())
 if (r/'foreign-map').exists(): value['metadata']['annotations']['nagare.dev/resource-id']='application:other/map/foreign'
 print(json.dumps(value));sys.exit(0)
owners=json.loads((r/'owners.json').read_text())
matches=[o for o in owners if o['kind']==kind.split('.')[0] and o['name']==name]
assert len(matches)==1,a
o=matches[0]
uid='en-uid' if name=='en' else name.split('.')[0]+'-route-uid'
if (r/'foreign-owner').exists(): uid='foreign-uid'
print(json.dumps({'metadata':{'uid':uid,'annotations':{
'nagare.dev/context-id':'access-test','nagare.dev/resource-id':o['resource'],
'nagare.dev/spec-digest':o['digest']}}}))
''')
        kubectl.chmod(0o700)
        env["PATH"] = str(root / "bin") + os.pathsep + env["PATH"]
        state = {"tuples": {("one.example.test", "bob"), ("two.example.test", "bob")},
                 "writes": 0, "lose": False, "old": False, "caveat": False, "race": False}
        neighbors = set(state["tuples"])
        failures = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def respond(self, code, body):
                data = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                assert self.path == "/v1/openapi.json"
                self.respond(200, {} if state["old"] else {"components": {"schemas": {
                    "WriteTuplesRequestWire": {"properties": {"preconditions": {}, "deletes": {}}}}}})

            def do_POST(self):
                try:
                    assert self.headers["Authorization"] == "Bearer fixture-private-key"
                    request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    exact = {"objectType": "app", "objectId": "one.example.test", "relation": "viewer",
                             "subjectType": "user", "subjectId": "alice", "subjectRelation": {"match": "none"}}
                    selected = ("one.example.test", "alice")
                    if self.path == "/v1/relationships/query?first=2":
                        assert request == {"consistency": {"mode": "fullyConsistent"}, "filter": exact}
                        nodes = [tuple_wire(*selected)] if selected in state["tuples"] else []
                        if state["caveat"]:
                            nodes = [dict(tuple_wire(*selected), caveat={"name": "foreign"})]
                        self.respond(200, {"edges": [{"node": node} for node in nodes],
                                           "pageInfo": {"hasNextPage": False}})
                        return
                    assert self.path == "/v1/relationships"
                    state["writes"] += 1
                    grant = bool(request["tuples"])
                    expected = tuple_wire(*selected)
                    assert request["tuples"] == ([expected] if grant else [])
                    assert request["deletes"] == ([] if grant else [expected])
                    assert request["preconditions"] == [{"kind": "mustNotExist" if grant else "mustExist", "filter": exact}]
                    if state["race"]:
                        self.respond(412, {"error": "condition changed"})
                        return
                    assert (selected in state["tuples"]) != grant
                    if grant:
                        state["tuples"].add(selected)
                    else:
                        state["tuples"].remove(selected)
                    if state["lose"]:
                        state["lose"] = False
                        self.connection.shutdown(socket.SHUT_RDWR)
                        self.connection.close()
                    else:
                        self.respond(200, {"token": "fixture-consistency-token"})
                except Exception as error:
                    failures.append(repr(error))
                    self.respond(500, {"error": "fixture assertion failed"})

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env["NAGARE_EN_URL"] = f"http://127.0.0.1:{server.server_port}"
        head_path = root / "state/nagare/access-test/inventory/head.json"

        def head():
            return json.loads(head_path.read_bytes())

        def run(*args, succeeds=True, variables=None):
            result = subprocess.run([cli, "--context", "access-test", *map(str, args)],
                                    env=variables or env, cwd=root, capture_output=True, timeout=45)
            output = result.stdout + result.stderr
            assert b"fixture-private-key" not in output, "credential leaked in command output"
            assert (result.returncode == 0) == succeeds, (args, result.returncode, output.decode())
            assert not failures, failures
            return result

        def plan(label, granted=True, succeeds=True, variables=None):
            directory = root / label
            run("access", "grant" if granted else "revoke", "--host", "one.example.test",
                "--user", "alice", "--save-plan", directory, succeeds=succeeds, variables=variables)
            return directory

        original = head()
        no_key = dict(env)
        del no_key["NAGARE_EN_API_KEY"]
        plan("missing-key", succeeds=False, variables=no_key)
        state["old"] = True
        plan("old-api", succeeds=False)
        state["old"] = False
        state["caveat"] = True
        plan("foreign-caveat", succeeds=False)
        state["caveat"] = False
        run("access", "grant", "--host", "foreign.example.test", "--user", "alice",
            "--save-plan", root / "foreign-host", succeeds=False)
        assert head() == original and state["writes"] == 0
        grant = plan("grant")
        document = json.loads((grant / "review.json").read_bytes())
        assert len(document["operations"]) == 1
        assert document["operations"][0]["operation"]["executor"] == "AccessExecutor"
        state["lose"] = True
        interrupted = run("inventory", "apply", grant, "--yes", succeeds=False)
        assert state["writes"] == 1 and head()["activeTransaction"] is not None, (interrupted.stdout + interrupted.stderr).decode()
        transaction = "tx-" + (grant / "review.sha256").read_text().strip()
        run("inventory", "resume", transaction, "--yes")
        assert state["writes"] == 1 and state["tuples"] == neighbors | {("one.example.test", "alice")}
        unchanged = plan("unchanged")
        run("inventory", "apply", unchanged, "--yes")
        assert state["writes"] == 1
        revoke = plan("revoke", granted=False)
        revoke_transaction = "tx-" + (revoke / "review.sha256").read_text().strip()
        (root / "foreign-owner").touch()
        run("inventory", "apply", revoke, "--yes", succeeds=False)
        (root / "foreign-owner").unlink()
        assert head()["activeTransaction"] is not None and state["writes"] == 1
        state["tuples"].remove(("one.example.test", "alice"))
        run("inventory", "resume", revoke_transaction, "--yes", succeeds=False)
        state["tuples"].add(("one.example.test", "alice"))
        assert head()["activeTransaction"] is not None and state["writes"] == 1
        run("inventory", "resume", revoke_transaction, "--yes")
        assert state["writes"] == 2 and state["tuples"] == neighbors
        final = head()
        assert final["activeTransaction"] is None and final["executorClaim"] is None
        run("inventory", "explain", document["operations"][0]["operation"]["resources"][0], "--json")
        kubeconfig = config / "kubeconfigs/access-test.yaml"
        kubeconfig.rename(kubeconfig.with_suffix(".retained"))
        unavailable = run("inventory", "explain", document["operations"][0]["operation"]["resources"][0], "--json")
        assert b"provider observation is unavailable" in unavailable.stdout
        assert head() == final and state["writes"] == 2
        kubeconfig.with_suffix(".retained").rename(kubeconfig)
        original_scopes = {json.dumps(row["scope"], sort_keys=True): row["revision"] for row in original["accepted"]}
        final_scopes = {json.dumps(row["scope"], sort_keys=True): row["revision"] for row in final["accepted"]}
        assert all(final_scopes[scope] == revision for scope, revision in original_scopes.items())
        backend_path = root / "nagare-access-backends.json"
        settings_path = root / "nagare-shomei-settings.json"
        backend_before = backend_path.read_bytes()
        desired_settings = json.loads(settings_path.read_text())["data"]
        drifted = json.loads(settings_path.read_text())
        drifted["data"]["public-base-url"] = "https://stale.example.test"
        settings_path.write_text(json.dumps(drifted))
        before_foreign = head_path.read_bytes()
        (root / "foreign-map").touch()
        run("access", "portal", "sync", "--save-plan", root / "foreign-portal", succeeds=False)
        (root / "foreign-map").unlink()
        assert head_path.read_bytes() == before_foreign and not (root / "map-writes").exists()
        portal = root / "portal"
        run("access", "portal", "sync", "--save-plan", portal)
        portal_review = json.loads((portal / "review.json").read_bytes())
        assert len(portal_review["operations"]) == 2
        assert all(operation["operation"]["executor"] == "KubernetesExecutor" for operation in portal_review["operations"])
        run("inventory", "apply", portal, "--yes")
        assert json.loads(settings_path.read_text())["data"] == desired_settings
        assert backend_path.read_bytes() == backend_before
        assert (root / "map-writes").read_text().splitlines() == ["nagare-shomei-settings", "shomei"]
        assert state["writes"] == 2 and state["tuples"] == neighbors
        for file in root.rglob("*.json"):
            assert b"fixture-private-key" not in file.read_bytes(), "credential leaked in review/history"
        server.shutdown()
        server.server_close()
        print("reviewed access public fixture: grant, lost-response resume, unchanged replay, revoke, owner/tuple refusals, complete portal sync and rollout, neighbors and credentials passed")


if __name__ == "__main__":
    main()
