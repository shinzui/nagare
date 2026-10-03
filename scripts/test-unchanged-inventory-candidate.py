#!/usr/bin/env python3
"""Tests for scripts/unchanged-inventory-candidate.py on a synthetic export."""

from __future__ import annotations

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

        busy = root / "busy"
        write_export(busy, active="tx-open")
        assert run(busy, root / "busy.json", "Platform:kourier").returncode != 0
    print("unchanged inventory candidate tests passed")


if __name__ == "__main__":
    main()
