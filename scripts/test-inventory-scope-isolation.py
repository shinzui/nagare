#!/usr/bin/env python3
"""Exercise a selected empty scope beside unrelated cloud and native owners."""

import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path


def run(cli: Path, root: Path, environment: dict[str, str], args: list[str]) -> str:
    result = subprocess.run(
        [str(cli), *args], cwd=root / "cli/nagarectl", env=environment,
        text=True, capture_output=True, check=False,
    )
    if result.returncode:
        raise AssertionError(
            f"nagarectl {' '.join(args)} failed ({result.returncode}):\n"
            f"{result.stdout}{result.stderr}"
        )
    return result.stdout


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: test-inventory-scope-isolation.py BUILT_NAGARECTL")
    cli = Path(sys.argv[1]).resolve(strict=True)
    root = Path(__file__).resolve().parent.parent
    fixture = json.loads((root / "cli/nagarectl/test/fixtures/inventory/valid.json").read_text())
    foundation = fixture["snapshot"][0]["declaration"]
    owner = {"kind": "Platform", "name": "cloud"}
    cloud_resource = {
        "identity": "platform:cloud/bucket/resource",
        "owner": owner,
        "executor": "PulumiExecutor",
        "address": {"tag": "GlobalBucket", "contents": "unrelated-bucket"},
        "aliases": [{"tag": "PulumiUrn", "contents":
            "urn:pulumi:local::nagare::gcp:storage/bucket:Bucket::unrelated"}],
        "spec": {"tag": "NativeObject", "contents": "a" * 64},
        "lifecycle": "Retain",
        "dataPolicy": {"tag": "Stateless"},
        "sensitivity": "Public",
        "dependencies": [],
        "delegations": [],
        "source": {"file": "fixture", "path": "unrelated"},
    }
    def bundle(declarations: list[dict]) -> dict:
        return {
            "declarations": declarations, "exports": [], "conditions": [],
            "contributions": [], "operations": [], "grants": [],
        }
    cloud = {"version": 1, "scope": owner,
        "bundles": [bundle([{"tag": "Managed", "contents": cloud_resource}])]}
    app = {"version": 1, "scope": {"kind": "Application", "name": "empty"},
        "bundles": [bundle([])]}
    candidate = {
        "version": 1,
        "context": {"identity": "isolated", "project": "project"},
        "base": [
            {"scope": foundation["scope"], "generation": 7},
            {"scope": owner, "generation": 1},
        ],
        "snapshot": [
            {"generation": 7, "declaration": foundation},
            {"generation": 1, "declaration": cloud},
        ],
        "reservations": [],
        "changes": [{"replace": app}],
    }

    with tempfile.TemporaryDirectory(prefix="nagare-scope-isolation-") as temporary:
        scratch = Path(temporary)
        candidate_file = scratch / "candidate.json"
        candidate_file.write_text(json.dumps(candidate))
        context_dir = scratch / "config/nagare/contexts"
        context_dir.mkdir(parents=True)
        (context_dir / "isolated.env").write_text(
            "CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=local\n"
        )
        marker = scratch / "provider-called"
        fake_bin = scratch / "bin"
        fake_bin.mkdir()
        for executable in ("npm", "pulumi", "gcloud", "kubectl"):
            fake = fake_bin / executable
            fake.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$0\" >> "
                + shlex.quote(str(marker)) + "\nexit 95\n"
            )
            fake.chmod(0o755)
        environment = {key: value for key, value in os.environ.items()
            if not key.startswith("NAGARE_") and not key.startswith("CLOUDSDK_")}
        environment.update({
            "XDG_CONFIG_HOME": str(scratch / "config"),
            "XDG_STATE_HOME": str(scratch / "state"),
            "CLOUDSDK_CORE_PROJECT": "project",
            "NAGARE_MODE": "local",
            "PATH": str(fake_bin) + os.pathsep + os.environ.get("PATH", ""),
        })
        compiled = scratch / "compiled"
        review = scratch / "review"
        run(cli, root, environment, ["inventory", "compile", "--input",
            str(candidate_file), "--out", str(compiled)])
        empty_store = scratch / "empty-state/nagare/isolated/inventory"
        empty_store.mkdir(parents=True)
        empty_head = empty_store / "head.json"
        empty_head.write_text(json.dumps({
            "version": 1, "generation": 0, "sequence": 0,
            "binding": {"identity": "isolated", "project": "project"},
            "clientIdentity": "scope-isolation-test", "accepted": [], "converged": [],
            "activeTransaction": None, "executorClaim": None,
        }, sort_keys=True, separators=(",", ":")))
        empty_head.chmod(0o600)
        empty_environment = environment | {"XDG_STATE_HOME": str(scratch / "empty-state")}
        run(cli, root, empty_environment, ["--context", "isolated", "inventory", "plan",
            "--inventory", str(compiled), "--out", str(scratch / "empty-review")])
        if marker.exists():
            raise AssertionError("initialized empty store invoked a provider: " + marker.read_text())
        run(cli, root, environment, ["--context", "isolated", "inventory", "plan",
            "--inventory", str(compiled), "--out", str(review)])
        document = json.loads((review / "review.json").read_text())
        if document["operations"]:
            raise AssertionError("selected empty scope planned unrelated provider operations")
        head_file = scratch / "state/nagare/isolated/inventory/head.json"
        before = json.loads(head_file.read_text())
        run(cli, root, environment, ["--context", "isolated", "inventory", "apply",
            str(review), "--yes"])
        after = json.loads(head_file.read_text())
        old_revisions = {entry["scope"]["name"]: entry["revision"]
            for entry in before["accepted"]}
        new_revisions = {entry["scope"]["name"]: entry["revision"]
            for entry in after["accepted"]}
        if any(old_revisions[name] != new_revisions.get(name)
               for name in ("cloud", "foundation")):
            raise AssertionError("unrelated accepted scope revisions changed")
        if "empty" not in new_revisions:
            raise AssertionError("selected empty application scope was not accepted")
        if marker.exists():
            raise AssertionError("unrelated provider executable was called: "
                + marker.read_text())
        print("inventory scope isolation: fresh and empty stores planned without unrelated provider processes")


if __name__ == "__main__":
    main()
