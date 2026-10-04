#!/usr/bin/env python3
"""Build an `inventory compile` input that replaces the selected accepted scopes
with their identical accepted declarations, from a private `inventory export`.

The snapshot, base generations and retained-incarnation reservations come from
the export's head, so the compiled candidate matches the store even after
renames, retirements or collections. Reservations mirror
Nagare.Resource.Inventory.claimsOf (direct address, aliases, derived Knative,
certificate and StatefulSet claims). A native verification harness uses it for
the runner's verify phase: an unchanged replan must have zero operations.

Usage: scripts/unchanged-inventory-candidate.py EXPORT_DIR OUTPUT_JSON KIND:NAME [KIND:NAME ...]
         [--add-packaged-scope NAME=MANIFEST --payload-root DIR]
The export is private (it can contain credentials); the output contains only
accepted declarations and claims.

--add-packaged-scope adds one new Platform scope NAME whose single Kubernetes
member is file-backed from MANIFEST (relative to the accepted payload root,
one document). A runner rehearsal uses it to plan exactly one CreateResource
through generic planning. It reads the manifest with yq, binds the spec digest
the way nagarectl's canonicalValue does (sorted compact JSON, integers only),
and orders the member after the accepted Namespace and kubeconfig members."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description="unchanged inventory candidate from a private export")
parser.add_argument("export", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("selected", nargs="*", help="accepted scopes to replace unchanged, as KIND:NAME")
parser.add_argument("--add-packaged-scope", metavar="NAME=MANIFEST")
parser.add_argument("--payload-root", type=Path)
args = parser.parse_args()
export, output, selected = args.export, args.output, set(args.selected)
head = json.loads((export / "head.json").read_text())
if head.get("activeTransaction"):
    raise SystemExit("export has an active transaction")

def find(node, rid):
    if isinstance(node, dict):
        if node.get("identity") == rid:
            return node
        for v in node.values():
            r = find(v, rid)
            if r: return r
    elif isinstance(node, list):
        for v in node:
            r = find(v, rid)
            if r: return r
    return None

# Mirrors Nagare.Resource.Inventory.canonicalClaim for every provider address kind.
CLAIM_PREFIX = {
    "GlobalBucket": "bucket", "CloudService": "cloud-service", "CloudStack": "cloud-stack",
    "CloudInstance": "instance", "PulumiUrn": "pulumi", "Host": "host", "Artifact": "artifact",
    "Hostname": "hostname", "DatabaseName": "database", "BackendRoute": "route",
    "AtticCache": "attic-cache", "BrokerTopic": "broker-topic", "Helm": "helm",
    "DnsRecord": "dns-record", "CloudflareDnsRecord": "cloudflare-dns-record",
}

def claim(addr):
    tag, c = addr["tag"], addr.get("contents")
    if tag == "Kubernetes":
        cluster, group, kind, ns, name = c
        return ["kubernetes", cluster, group.lower(), kind, ns or "", name]
    if tag == "AccessTuple":
        return ["access-tuple", *c, "viewer"]
    if tag == "CloudflareRuleset":
        return ["cloudflare-ruleset", c, "http_request_cache_settings"]
    if tag == "CloudflareTlsSetting":
        return ["cloudflare-tls-setting", c, "ssl"]
    if tag in CLAIM_PREFIX:
        return [CLAIM_PREFIX[tag], *(c if isinstance(c, list) else [c])]
    raise SystemExit(f"unsupported retained address kind {tag}")

def derived(decl):
    a, s = decl["address"], decl["spec"]
    if a["tag"] != "Kubernetes": return []
    cluster, group, kind, ns, name = a["contents"]
    out = []
    if s["tag"] == "KnativeService":
        out.append(["kubernetes", cluster, "", "service", ns or "", name])
    elif s["tag"] == "Certificate":
        out.append(["kubernetes", cluster, "", "secret", ns or "", s["contents"][0]])
    elif s["tag"] == "StatefulSet":
        replicas, templates, _ = s["contents"]
        replicas = replicas if 0 <= replicas <= 10000 else 0
        out += [["kubernetes", cluster, "", "pod", ns or "", f"{name}-{i}"] for i in range(replicas)]
        out += [["kubernetes", cluster, "", "persistentvolumeclaim", ns or "", f"{t}-{name}-{i}"] for t in templates for i in range(replicas)]
    elif s["tag"] == "HelmRelease":
        raise SystemExit("retained Helm release reservations are not supported by this helper")
    return out

# Like Nagare.Inventory.Plan.Types.retainedReservations (Map.fromList over retained resources
# in ascending id order): when two retained incarnations share a claim, such as a DNS record
# and its DomainMapping aliasing one hostname, the greater resource id holds it.
reserved = {}
for entry in sorted(head.get("retained", []), key=lambda e: e["resource"]):
    rid, inc = entry["resource"], entry["incarnation"]
    scope = json.loads((export / "scopes" / f"{inc['revision']['digest']}.json").read_text())
    decl = find(scope, rid)
    if decl is None:
        raise SystemExit(f"retained declaration not found: {rid}")
    claims = [claim(decl["address"])] + [claim(x) for x in decl.get("aliases", [])] + derived(decl)
    holder = [inc["owner"], rid, inc["physical"], "RetainedIncarnation"]
    reserved.update({json.dumps(c): {"claim": c, "holder": holder} for c in claims})
reservations = list(reserved.values())

snapshot, base, changes = [], [], []
for entry in head["accepted"]:
    revision, scope = entry["revision"], entry["scope"]
    declaration = json.loads((export / "scopes" / f"{revision['digest']}.json").read_text())
    snapshot.append({"generation": revision["generation"], "declaration": declaration})
    base.append({"scope": scope, "generation": revision["generation"]})
    if f"{scope['kind']}:{scope['name']}" in selected:
        changes.append({"replace": declaration})
if len(changes) != len(selected):
    raise SystemExit("a selected scope is not accepted")
def canonical(value):
    if isinstance(value, dict):
        return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + canonical(value[k]) for k in sorted(value)) + "}"
    if isinstance(value, list):
        return "[" + ",".join(canonical(v) for v in value) + "]"
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, int):
        return str(value)
    raise SystemExit("packaged manifest contains a non-integer number")


def packaged_scope(spec_text, payload_root, accepted_declarations):
    name, _, manifest = spec_text.partition("=")
    if not name or not manifest or payload_root is None:
        raise SystemExit("--add-packaged-scope NAME=MANIFEST requires --payload-root")
    path = payload_root / manifest
    if not path.is_file() or manifest.startswith("/") or ".." in Path(manifest).parts:
        raise SystemExit(f"packaged manifest is missing or escapes the payload: {manifest}")
    documents = subprocess.run(["yq", "-o=json", "-I=0", ".", str(path)], check=True, capture_output=True, text=True).stdout.strip().splitlines()
    if len(documents) != 1:
        raise SystemExit("packaged manifest must hold exactly one document")
    document = json.loads(documents[0])
    api, kind, meta = document["apiVersion"], document["kind"].lower(), document["metadata"]
    group = api.split("/", 1)[0] if "/" in api else ""
    managed = [d["contents"] for d in accepted_declarations if d.get("tag") == "Managed"]
    clusters = {d["address"]["contents"][0] for d in managed if d["address"]["tag"] == "Kubernetes"}
    if len(clusters) != 1:
        raise SystemExit("accepted Kubernetes declarations name more than one cluster")
    namespace = meta.get("namespace")
    if (group, kind) == ("serving.knative.dev", "service"):
        spec = {"tag": "KnativeService", "contents": hashlib.sha256(canonical(document).encode()).hexdigest()}
    elif kind in ("configmap", "service"):
        spec = {"tag": "NativeObject", "contents": hashlib.sha256(canonical(document).encode()).hexdigest()}
    else:
        raise SystemExit(f"packaged scope supports only a ConfigMap, Service or Knative Service, not {kind}")
    dependencies = sorted(
        d["identity"]
        for d in managed
        if d["identity"].startswith("platform:kubeconfig/")
        or (namespace and d["address"]["tag"] == "Kubernetes" and d["address"]["contents"][2] == "namespace" and d["address"]["contents"][4] == namespace)
    )
    scope = {"kind": "Platform", "name": name}
    declaration = {
        "tag": "Managed",
        "contents": {
            "address": {"tag": "Kubernetes", "contents": [clusters.pop(), group, kind, namespace, meta["name"]]},
            "aliases": [],
            "dataPolicy": {"tag": "Stateless"},
            "delegations": [],
            "dependencies": [{"tag": "OrderedAfter", "contents": d} for d in dependencies],
            "executor": "KubernetesExecutor",
            "identity": f"platform:{name}/{name}/{meta['name']}",
            "lifecycle": "Retain",
            "owner": scope,
            "sensitivity": "Private",
            "source": {"file": manifest, "path": f"{name}#document[0]"},
            "spec": spec,
        },
    }
    bundle = {"conditions": [], "contributions": [], "declarations": [declaration], "exports": [], "grants": [], "operations": []}
    return {"scope": scope, "version": 1, "bundles": [bundle]}


if args.add_packaged_scope:
    accepted_declarations = [
        declaration
        for item in snapshot
        for bundle in item["declaration"].get("bundles", [])
        for declaration in bundle.get("declarations", [])
    ]
    added = packaged_scope(args.add_packaged_scope, args.payload_root, accepted_declarations)
    if any(item["declaration"]["scope"] == added["scope"] for item in snapshot):
        raise SystemExit("the packaged scope is already accepted")
    changes.append({"replace": added})
reservations.sort(key=lambda r: r["claim"])
output.write_text(json.dumps({"version": 1, "context": head["binding"], "base": base, "snapshot": snapshot,
                              "reservations": reservations, "changes": changes}, indent=1) + "\n")
print(f"{len(snapshot)} accepted scopes, {len(changes)} unchanged replacements, {len(reservations)} reservations")
