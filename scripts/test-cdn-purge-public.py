#!/usr/bin/env python3
"""Exercise public reviewed CDN purge against a private TLS recording proxy.

Only the child process trusts the ephemeral CA; no real provider is contacted.
"""

import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import ssl
import socketserver
import threading
from http.server import BaseHTTPRequestHandler


REPO = Path(__file__).resolve().parents[1]
PROJECT = REPO / "cli/nagarectl"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--nagarectl", type=Path, help="executable to verify")
parser.add_argument("--last-contributor", action="store_true", help="Verify the Retain namespace survives its last workload")
parser.add_argument("--google-dns", action="store_true", help="Test Google DNS collection instead of Cloudflare purge")
parser.add_argument("--collection", action="store_true", help="Also retire and collect only the owned DNS record")
parser.add_argument("--ambiguous-response", choices=["drop", "redirect"], default="drop")
options = parser.parse_args()
if options.google_dns:
    options.collection = True
root = Path(tempfile.mkdtemp(prefix="mp23-cdn-purge-public-"))
print(f"Artifacts: {root}", flush=True)
store = root / "state/nagare/cdn-purge-fixture/inventory"
binary = str(options.nagarectl.absolute()) if options.nagarectl else subprocess.check_output(
    ["cabal", "list-bin", "exe:nagarectl", "--enable-tests"], cwd=PROJECT, text=True
).strip()
subprocess.run([
    "cabal", "exec", "--", "runghc", "-package=nagarectl", "-package=nagare-dsl",
    "-XGHC2024", "-XDeriveAnyClass", "-XDuplicateRecordFields", "-XOverloadedLabels",
    "-XOverloadedStrings", str(REPO / "scripts/fixtures/CdnPurgePublicFixture.hs"),
    str(store), str(root),
] + ["google" if options.google_dns else "cloudflare", "last" if options.last_contributor else "shared"], cwd=PROJECT, check=True, timeout=90)
(root / "dns-state.json").write_text(json.dumps("203.0.113.4"))
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
(config / "contexts/cdn-purge-fixture.env").write_text(
    "CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=local\n"
    "NAGARE_INVENTORY_STORE=local\nNAGARE_PLATFORM_VERSION=0.4.0\nNAGARE_BASE_DOMAIN=example.test\n")
(config / "kubeconfigs").mkdir()
(config / "kubeconfigs/cdn-purge-fixture.yaml").write_text("apiVersion: v1\nkind: Config\n")
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
    if args==['auth','print-access-token']:
        print('fixture-access-token');sys.exit(0)
    if args==['config','get-value','project']:
        print('project');sys.exit(0)
    if args[:3]==['dns','record-sets','list'] and len(args)==8 and args[3] in ['--name=www.example.test.','--name=example.test.'] and args[4:]==['--type=A','--zone=zone','--format=json','--project=project']:
        target=json.loads((root/'dns-state.json').read_text()) if args[3]=='--name=www.example.test.' else '203.0.113.4'
        print(json.dumps([{'name':args[3].split('=',1)[1],'type':'A','ttl':300,'rrdatas':[target]}] if target else []));sys.exit(0)
if tool=='pulumi' and args[:1]==['-C']:
    operation=args[2:]
    if operation==['stack','select','cdn-purge-fixture']:
        sys.exit(0)
    if operation==['config','--json','--stack','cdn-purge-fixture','--non-interactive']:
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
            'nagare.dev/context-id':'cdn-purge-fixture',
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

cert = root / "proxy-cert.pem"
key = root / "proxy-key.pem"
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-keyout", str(key), "-out", str(cert), "-subj", "/CN=api.cloudflare.com",
                "-addext", "subjectAltName=DNS:api.cloudflare.com,DNS:dns.googleapis.com"], check=True, capture_output=True)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
zone = "0123456789abcdef0123456789abcdef"
api = "/client/v4/zones/" + zone
http_calls = []
purges = []
deletions = []
behavior = {"absent": False, "lose": False, "record_id": "record1", "rules_id": "rules1", "rules_version": "1"}
rules = json.loads((root / "rules.json").read_text())["rules"]


class API(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, result):
        data = json.dumps({"success": True, "errors": [], "messages": [], "result": result,
                           "result_info": {"count": len(result) if isinstance(result, list) else 1, "page": 1}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        assert self.headers.get("Authorization") == "Bearer fixture-only-token"
        http_calls.append(["GET", self.path])
        if self.path == api:
            self.answer({"id": zone, "account": {"id": "fixture-account"}})
        elif self.path == api + "/settings/ssl":
            self.answer({"id": "ssl", "value": "strict", "modified_on": "tls-version-1"})
        elif self.path == api + "/rulesets/phases/http_request_cache_settings/entrypoint":
            self.answer({"id": behavior["rules_id"], "version": behavior["rules_version"], "kind": "zone", "phase": "http_request_cache_settings", "rules": behavior.get("rules", rules)})
        elif self.path == api + "/dns_records?type=A&name.exact=www.example.test&per_page=2":
            self.answer([] if behavior["absent"] else [{"id": behavior["record_id"], "type": "A", "name": "www.example.test",
                          "content": "203.0.113.4", "proxied": True, "ttl": 1, "modified_on": "dns-version-1"}])
        else:
            self.send_error(599, "unexpected recorded read")

    def do_PUT(self):
        assert options.collection
        assert self.path == api + "/rulesets/phases/http_request_cache_settings/entrypoint"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert body["rules"] == [], body
        http_calls.append(["PUT", self.path, body])
        behavior["rules"] = []
        behavior["rules_version"] = "2"
        self.answer({"id": "rules1"})

    def do_DELETE(self):
        assert options.collection
        assert self.path == api + "/dns_records/record1"
        assert not int(self.headers.get("Content-Length", "0"))
        http_calls.append(["DELETE", self.path])
        deletions.append(self.path)
        behavior["absent"] = True
        self.close_connection = True  # provider effect with lost acknowledgement

    def do_POST(self):
        if options.google_dns:
            assert self.headers.get("Authorization") == "Bearer fixture-access-token"
            assert self.path == "/dns/v1/projects/project/managedZones/zone/changes"
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert body == {"additions": [], "deletions": [{"name": "www.example.test.", "type": "A", "ttl": 300, "rrdatas": ["203.0.113.4"]}]}
            assert json.loads((root / "dns-state.json").read_text()) == "203.0.113.4"
            http_calls.append(["POST", self.path, body])
            deletions.append(self.path)
            (root / "dns-state.json").write_text("null")
            self.close_connection = True
            return
        assert self.headers.get("Authorization") == "Bearer fixture-only-token"
        assert self.path == api + "/purge_cache", self.path
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert body in [{"files": ["https://www.example.test/selected"]}, {"hosts": ["www.example.test"]}, {"purge_everything": True}], body
        http_calls.append(["POST", self.path, body])
        purges.append(body)
        if behavior["lose"] and options.ambiguous_response == "redirect":
            self.send_response(307)
            self.send_header("Location", self.path)
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif behavior["lose"]:
            self.close_connection = True
        else:
            self.answer({"id": "accepted" + str(len(purges))})


class Proxy(socketserver.StreamRequestHandler):
    def handle(self):
        expected = b"CONNECT dns.googleapis.com:443 HTTP/1.1" if options.google_dns else b"CONNECT api.cloudflare.com:443 HTTP/1.1"
        assert self.rfile.readline().strip() == expected
        while self.rfile.readline().strip():
            pass
        self.wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        self.wfile.flush()
        with context.wrap_socket(self.connection, server_side=True) as connection:
            API(connection, self.client_address, self.server)


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def run(arguments, success=True):
    result = subprocess.run([binary, "--context", "cdn-purge-fixture", *arguments],
                            cwd=root, env=env, capture_output=True, text=True, timeout=45)
    with (root / "results.jsonl").open("a") as out:
        out.write(json.dumps({"args": arguments, "exit": result.returncode,
                              "stdout": result.stdout, "stderr": result.stderr}) + "\n")
    (root / "http-calls.json").write_text(json.dumps(http_calls, indent=2) + "\n")
    assert (result.returncode == 0) == success, (arguments, result.stdout, result.stderr)
    return result


with Server(("127.0.0.1", 0), Proxy) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env.update(CF_API_TOKEN="fixture-only-token", CF_ZONE_ID=zone, CF_ACCOUNT_ID="fixture-account",
               SSL_CERT_FILE=str(cert), SSL_CERT_DIR=str(root / "empty-ca-dir"),
               https_proxy=f"http://127.0.0.1:{server.server_address[1]}",
               HTTPS_PROXY=f"http://127.0.0.1:{server.server_address[1]}", NO_PROXY="", no_proxy="")
    (root / "empty-ca-dir").mkdir()
    if not options.google_dns:
        review = str(root / "purge-review")
        run(["cdn", "purge", "www.example.test", "--path", "/selected", "--purge-id", "first", "--save-plan", review])
        assert (store / "head.json").read_bytes() == initial_head
        assert not purges
        run(["inventory", "apply", review, "--yes"])
        assert purges == [{"files": ["https://www.example.test/selected"]}]
        run(["inventory", "resume", "tx-" + (Path(review) / "review.sha256").read_text().strip(), "--yes"])
        assert len(purges) == 1
        replay = str(root / "replay-review")
        run(["cdn", "purge", "www.example.test", "--path", "/selected", "--purge-id", "first", "--save-plan", replay])
        operations = json.loads((Path(replay) / "review.json").read_text())["operations"]
        assert all(item["operation"]["action"]["tag"] != "RunDeclaredOperation" for item in operations)
        changed = str(root / "changed-review")
        run(["cdn", "purge", "www.example.test", "--purge-id", "changed", "--save-plan", changed])
        behavior["record_id"] = "foreign-record"
        if options.google_dns:
            (root / "dns-state.json").write_text(json.dumps("203.0.113.5"))
        run(["inventory", "apply", changed, "--yes"], False)
        assert len(purges) == 1
        behavior["record_id"] = "record1"
        if options.google_dns:
            (root / "dns-state.json").write_text(json.dumps("203.0.113.4"))
        run(["inventory", "resume", "tx-" + (Path(changed) / "review.sha256").read_text().strip(), "--yes"])
        assert purges[-1] == {"hosts": ["www.example.test"]}
        before = len(http_calls)
        run(["cdn", "purge", "foreign.example.test", "--purge-id", "bad", "--save-plan", str(root / "foreign")], False)
        assert len(http_calls) == before
        zone_review = str(root / "zone-review")
        run(["cdn", "purge", "www.example.test", "--whole-zone", "--purge-id", "zone", "--save-plan", zone_review])
        assert "ALL cached content in zone" in (Path(zone_review) / "review.json").read_text()
        behavior["rules_version"] = "2"
        run(["inventory", "apply", zone_review, "--yes"], False)
        assert len(purges) == 2
        behavior["rules_version"] = "1"
        behavior["rules_id"] = "foreign-rules"
        run(["inventory", "resume", "tx-" + (Path(zone_review) / "review.sha256").read_text().strip(), "--yes"], False)
        assert len(purges) == 2
        behavior["rules_id"] = "rules1"
        run(["inventory", "resume", "tx-" + (Path(zone_review) / "review.sha256").read_text().strip(), "--yes"])
        assert purges[-1] == {"purge_everything": True}
        run(["inventory", "resume", "tx-" + (Path(zone_review) / "review.sha256").read_text().strip(), "--yes"])
        assert len(purges) == 3
        before = len(http_calls)
        run(["cdn", "purge", "www.example.test", "--whole-zone", "--path", "/selected", "--purge-id", "invalid", "--save-plan", str(root / "invalid-zone")], False)
        run(["cdn", "purge", "www.example.test", "--whole-zone"], False)
        assert len(http_calls) == before
    if options.collection:
        retirement = str(root / "retire-review")
        run(["inventory", "retire", "--scope", "application:demo", "--out", retirement])
        run(["inventory", "apply", retirement, "--yes"])
        assert not deletions and not behavior["absent"]
        head = json.loads((store / "head.json").read_text())
        retained = {entry["resource"]: entry for entry in head["retained"]}
        dns_ids = [resource for resource in retained if resource.endswith("/dns-a") or resource.endswith("/cloudflare-dns-a")]
        assert len(dns_ids) == 1, retained
        dns_id = dns_ids[0]
        collection = str(root / "collection-review")
        run(["inventory", "collect", "--resource", dns_id, "--out", collection])
        behavior["record_id"] = "foreign-record"
        if options.google_dns:
            (root / "dns-state.json").write_text(json.dumps("203.0.113.5"))
        run(["inventory", "apply", collection, "--yes"], False)
        assert not deletions
        behavior["record_id"] = "record1"
        if options.google_dns:
            (root / "dns-state.json").write_text(json.dumps("203.0.113.4"))
        tx = "tx-" + (Path(collection) / "review.sha256").read_text().strip()
        run(["inventory", "resume", tx, "--yes"], False)
        assert len(deletions) == 1
        run(["inventory", "resume", tx, "--yes"])
        run(["inventory", "resume", tx, "--yes"])
        assert len(deletions) == 1
        after = json.loads((store / "head.json").read_text())
        retained_after = {entry["resource"]: entry for entry in after.get("retained", [])}
        collected_after = {entry["resource"]: entry for entry in after.get("collected", [])}
        assert dns_id not in retained_after and dns_id in collected_after
        assert {k:v for k,v in retained.items() if k != dns_id} == retained_after
        assert head["accepted"] == after["accepted"]
    else:
        lost = str(root / "lost-review")
        run(["cdn", "purge", "www.example.test", "--purge-id", "lost", "--save-plan", lost])
        behavior["lose"] = True
        run(["inventory", "apply", lost, "--yes"], False)
        count = len(purges)
        run(["inventory", "resume", "tx-" + (Path(lost) / "review.sha256").read_text().strip(), "--yes"], False)
        assert len(purges) == count == 4
    assert not (root / "unexpected-calls.jsonl").exists()
    (root / "http-calls.json").write_text(json.dumps(http_calls, indent=2) + "\n")
    server.shutdown()
if options.collection:
    print("Public " + ("Google" if options.google_dns else "Cloudflare") + " DNS collection passed: retained hostname pair, changed-record refusal, exact deletion, lost-response recovery without resend, and preserved namespace/neighbors.")
else:
    print("Public CDN purge passed: exact URL/host/explicit-zone targets, immutable replay, changed identity refusal and unresolved acknowledgement without resend.")
