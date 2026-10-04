#!/usr/bin/env python3
"""Tests for scripts/unchanged-inventory-candidate.py on a synthetic export."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/unchanged-inventory-candidate.py"
CLUSTER = "platform:cluster/cluster/cluster"


def address(kind: str, namespace: str, name: str, group: str = "") -> dict:
    return {"tag": "Kubernetes", "contents": [CLUSTER, group, kind, namespace, name]}


def write_export(root: Path, *, active: str | None = None) -> None:
    (root / "scopes").mkdir(parents=True)
    platform = {"scope": {"kind": "Platform", "name": "kourier"}, "bundles": []}
    retired = {
        "scope": {"kind": "Standalone", "name": "database-old"},
        "bundles": [
            {
                "declarations": [
                    {
                        "identity": "standalone:database-old/old/statefulset",
                        "address": address("statefulset", "personal", "old", "apps"),
                        "aliases": [address("service", "personal", "old-alias")],
                        "spec": {"tag": "StatefulSet", "contents": [2, ["data"], "digest"]},
                    }
                ]
            }
        ],
    }
    (root / "scopes/platform.json").write_text(json.dumps(platform))
    (root / "scopes/retired.json").write_text(json.dumps(retired))
    head = {
        "activeTransaction": active,
        "binding": {"identity": "local"},
        "accepted": [{"scope": platform["scope"], "revision": {"digest": "platform", "generation": 3}}],
        "retained": [
            {
                "resource": "standalone:database-old/old/statefulset",
                "incarnation": {
                    "owner": retired["scope"],
                    "physical": "uid-old",
                    "revision": {"digest": "retired", "generation": 1},
                },
            }
        ],
    }
    (root / "head.json").write_text(json.dumps(head))


def run(export: Path, output: Path, *selected: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(export), str(output), *selected],
        capture_output=True,
        text=True,
        check=False,
    )


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        export = root / "export"
        write_export(export)
        output = root / "candidate.json"
        result = run(export, output, "Platform:kourier")
        assert result.returncode == 0, result.stderr
        candidate = json.loads(output.read_text())
        assert candidate["base"] == [{"scope": {"kind": "Platform", "name": "kourier"}, "generation": 3}]
        assert len(candidate["changes"]) == 1
        claims = [reservation["claim"] for reservation in candidate["reservations"]]
        # Direct address, alias, two ordinal Pods and two volume-claim templates.
        assert claims == sorted(claims) and len(claims) == 6, claims
        assert ["kubernetes", CLUSTER, "apps", "statefulset", "personal", "old"] in claims
        assert ["kubernetes", CLUSTER, "", "service", "personal", "old-alias"] in claims
        assert ["kubernetes", CLUSTER, "", "pod", "personal", "old-1"] in claims
        assert ["kubernetes", CLUSTER, "", "persistentvolumeclaim", "personal", "data-old-0"] in claims
        holders = {json.dumps(reservation["holder"]) for reservation in candidate["reservations"]}
        assert holders == {
            json.dumps([{"kind": "Standalone", "name": "database-old"}, "standalone:database-old/old/statefulset", "uid-old", "RetainedIncarnation"])
        }

        # A retained Google DNS record reserves its record and hostname alias claims, in the
        # address shape a real cloud export holds (F48 rehearsal on mp23-c3g).
        dns_export = root / "dns-export"
        write_export(dns_export)
        retired = json.loads((dns_export / "scopes/retired.json").read_text())
        host = "www.example.test"
        retired["bundles"][0]["declarations"].append({
            "identity": f"standalone:database-old/{host}/dns-a",
            "address": {"tag": "DnsRecord", "contents": ["project", "zone", host]},
            "aliases": [{"tag": "Hostname", "contents": host}],
            "spec": {"tag": "DnsARecord", "contents": ["203.0.113.4", 300]},
        })
        (dns_export / "scopes/retired.json").write_text(json.dumps(retired))
        head = json.loads((dns_export / "head.json").read_text())
        head["retained"].append({"resource": f"standalone:database-old/{host}/dns-a",
                                 "incarnation": {"owner": retired["scope"], "physical": "dns:project/zone/www",
                                                 "revision": {"digest": "retired", "generation": 1}}})
        (dns_export / "head.json").write_text(json.dumps(head))
        result = run(dns_export, root / "dns.json", "Platform:kourier")
        assert result.returncode == 0, result.stderr
        dns_claims = {json.dumps(r["claim"]): r["holder"][1] for r in json.loads((root / "dns.json").read_text())["reservations"]}
        assert dns_claims.get(json.dumps(["dns-record", "project", "zone", host])) == f"standalone:database-old/{host}/dns-a", dns_claims
        assert dns_claims.get(json.dumps(["hostname", host])) == f"standalone:database-old/{host}/dns-a", dns_claims
        # A retained DomainMapping aliasing the same hostname shares that claim; as in the CLI's
        # retainedReservations, the greater resource id holds it and the claim appears once.
        retired["bundles"][0]["declarations"].append({
            "identity": f"standalone:database-old/{host}/domain-mapping",
            "address": address("domainmapping", "personal", host, "serving.knative.dev"),
            "aliases": [{"tag": "Hostname", "contents": host}],
            "spec": {"tag": "NativeObject", "contents": "digest"},
        })
        (dns_export / "scopes/retired.json").write_text(json.dumps(retired))
        head["retained"].insert(0, {"resource": f"standalone:database-old/{host}/domain-mapping",
                                    "incarnation": {"owner": retired["scope"], "physical": "uid-dm",
                                                    "revision": {"digest": "retired", "generation": 1}}})
        (dns_export / "head.json").write_text(json.dumps(head))
        result = run(dns_export, root / "shared.json", "Platform:kourier")
        assert result.returncode == 0, result.stderr
        shared = json.loads((root / "shared.json").read_text())["reservations"]
        hostname = [r["holder"][1] for r in shared if r["claim"] == ["hostname", host]]
        assert hostname == [f"standalone:database-old/{host}/domain-mapping"], hostname

        assert run(export, root / "missing.json", "Platform:absent").returncode != 0

        # An export without retained incarnations omits the key entirely.
        bare = root / "bare"
        write_export(bare)
        head = json.loads((bare / "head.json").read_text())
        del head["retained"]
        (bare / "head.json").write_text(json.dumps(head))
        result = run(bare, root / "bare.json", "Platform:kourier")
        assert result.returncode == 0, result.stderr
        assert json.loads((root / "bare.json").read_text())["reservations"] == []

        # One packaged single-document manifest becomes a new file-backed scope.
        payload = root / "payload"
        (payload / "cluster/examples/probe").mkdir(parents=True)
        (payload / "cluster/examples/probe/configmap.yaml").write_text(
            "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: probe\n  namespace: personal\ndata:\n  mode: \"1\"\n"
        )
        foundation = {
            "scope": {"kind": "Platform", "name": "foundation"},
            "bundles": [{"declarations": [{"tag": "Managed", "contents": {"identity": "platform:foundation/foundation/namespace-personal", "address": address("namespace", None, "personal")}}]}],
        }
        added_export = root / "added"
        write_export(added_export)
        (added_export / "scopes/foundation.json").write_text(json.dumps(foundation))
        head = json.loads((added_export / "head.json").read_text())
        head["accepted"].append({"scope": foundation["scope"], "revision": {"digest": "foundation", "generation": 1}})
        (added_export / "head.json").write_text(json.dumps(head))
        packaged = run(added_export, root / "added.json", "Platform:kourier", "--add-packaged-scope", "probe=cluster/examples/probe/configmap.yaml", "--payload-root", str(payload))
        assert packaged.returncode == 0, packaged.stderr
        changes = json.loads((root / "added.json").read_text())["changes"]
        assert [change["replace"]["scope"] for change in changes] == [{"kind": "Platform", "name": "kourier"}, {"kind": "Platform", "name": "probe"}]
        member = changes[1]["replace"]["bundles"][0]["declarations"][0]["contents"]
        canonical = '{"apiVersion":"v1","data":{"mode":"1"},"kind":"ConfigMap","metadata":{"name":"probe","namespace":"personal"}}'
        assert member["spec"] == {"tag": "NativeObject", "contents": hashlib.sha256(canonical.encode()).hexdigest()}, member["spec"]
        assert member["address"]["contents"] == [CLUSTER, "", "configmap", "personal", "probe"]
        assert member["source"] == {"file": "cluster/examples/probe/configmap.yaml", "path": "probe#document[0]"}
        assert member["dependencies"] == [{"tag": "OrderedAfter", "contents": "platform:foundation/foundation/namespace-personal"}]
        escaping = run(added_export, root / "escape.json", "--add-packaged-scope", "probe=../outside.yaml", "--payload-root", str(payload))
        assert escaping.returncode != 0

        busy = root / "busy"
        write_export(busy, active="tx-open")
        assert run(busy, root / "busy.json", "Platform:kourier").returncode != 0
    print("unchanged inventory candidate tests passed")


if __name__ == "__main__":
    main()
