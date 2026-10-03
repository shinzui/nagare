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
The export is private (it can contain credentials); the output contains only
accepted declarations and claims."""
import json, sys
from pathlib import Path

export, output = Path(sys.argv[1]), Path(sys.argv[2])
selected = set(sys.argv[3:])
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

def claim(addr):
    tag, c = addr["tag"], addr.get("contents")
    if tag == "Kubernetes":
        cluster, group, kind, ns, name = c
        return ["kubernetes", cluster, group.lower(), kind, ns or "", name]
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

reservations = []
for entry in head["retained"]:
    rid, inc = entry["resource"], entry["incarnation"]
    scope = json.loads((export / "scopes" / f"{inc['revision']['digest']}.json").read_text())
    decl = find(scope, rid)
    if decl is None:
        raise SystemExit(f"retained declaration not found: {rid}")
    claims = [claim(decl["address"])] + [claim(x) for x in decl.get("aliases", [])] + derived(decl)
    holder = [inc["owner"], rid, inc["physical"], "RetainedIncarnation"]
    reservations += [{"claim": c, "holder": holder} for c in claims]

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
reservations.sort(key=lambda r: r["claim"])
output.write_text(json.dumps({"version": 1, "context": head["binding"], "base": base, "snapshot": snapshot,
                              "reservations": reservations, "changes": changes}, indent=1) + "\n")
print(f"{len(snapshot)} accepted scopes, {len(changes)} unchanged replacements, {len(reservations)} reservations")
