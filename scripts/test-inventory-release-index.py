#!/usr/bin/env python3
"""Exercise the complete candidate gate and representative missing/stale inputs."""

import hashlib
import runpy
import json
import subprocess
import shutil
import sys
import tempfile
from pathlib import Path


ASSEMBLER = Path(__file__).with_name("assemble-inventory-release-index.py")
CONTRACT = runpy.run_path(str(ASSEMBLER))
REVISION = "fixture-revision"
VERSION = "0.4.0"
SYSTEMS = ["x86_64-linux", "aarch64-darwin"]
HEX_A = "a" * 64
HEX_B = "b" * 64


def write(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def read(path: Path) -> dict:
    return json.loads(path.read_text())


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_sha(value: dict) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    return hashlib.sha256(encoded.encode()).hexdigest()


def run(root: Path, success: bool, expected: str = "") -> None:
    command = [sys.executable, str(ASSEMBLER),
               "--release-metadata", str(root / "release.json"),
               "--release-manifest", str(root / "nagare-release-0.4.0.json"),
               "--native-dir", str(root / "native"),
               "--coverage-result", str(root / "coverage.json"),
               "--local-dir", str(root / "local"),
               "--cloud-dir", str(root / "cloud"),
               "--output", str(root / "index.json")]
    result = subprocess.run(command, text=True, capture_output=True)
    assert (result.returncode == 0) == success, (result.stdout, result.stderr)
    if expected:
        assert expected in result.stderr, result.stderr


with tempfile.TemporaryDirectory(prefix="nagare-inventory-index-test.") as temporary:
    root = Path(temporary)
    payloads = {system: "sha256-payload-" + system for system in SYSTEMS}
    write(root / "release.json", {"platformVersion": VERSION,
                                   "supportedSystems": SYSTEMS})
    write(root / "nagare-release-0.4.0.json",
          {"version": VERSION, "revision": REVISION, "consistent": True,
           "systems": SYSTEMS, "payloadDigests": payloads})
    write(root / "coverage.json",
          {"schemaVersion": 1, "complete": True, "dirty": False,
           "sourceRevision": REVISION, "candidateDigest": HEX_A,
           "registeredRoutes": 1, "recipes": 1, "libraryCalls": 1,
           "pending": [], "pendingRecipes": [],
           "incompleteCatalogueRows": [], "errors": [],
           "deferredRoutes": ["DbCommand.DbPruneScheduledBackups", "DbCommand.DbRestore.--into-live",
                              "DbCommand.DbShell", "StorageCommand.StorageRestore.--into-live"],
           "recoveryOnlyRoutes": ["DbCommand.DbRecoverScheduledPrune"]})
    for system in SYSTEMS:
        write(root / "native" / f"nix-output-{system}.json",
              {"version": VERSION, "revision": REVISION, "system": system,
               "outputs": {"nagarectl": {"narHash": "sha256-cli"},
                           "nagare-platform": {"narHash": payloads[system]}}})
        write(root / "native" / f"clone-free-{system}.json",
              {"version": VERSION, "revision": REVISION, "system": system,
               "supportedSystems": SYSTEMS, "cloneFree": True,
               "checks": ["version", "context", "typed-config", "inventory-compile", "payload", "operator-recipe"]})
    for mode, system in (("local", "aarch64-darwin"), ("cloud", "x86_64-linux")):
        directory = root / mode
        target = {"schemaVersion": 1, "mode": mode,
                  "context": "fixture-" + mode, "kubeContext": "k3d-" + mode,
                  "expectedCluster": "cluster-" + mode,
                  "expectedProject": "fixture-project" if mode == "cloud" else None}
        (directory / "target.json").parent.mkdir(parents=True, exist_ok=True)
        (directory / "target.json").write_text(json.dumps(target, indent=2) + "\n")
        write(directory / "fixture.json", {"schemaVersion": 1, "mode": mode,
                                            "description": "synthetic complete scenario"})
        write(directory / f"{mode}-health.json",
              {"schemaVersion": 1, "mode": mode, "context": target["context"],
               "cluster": target["expectedCluster"], "operatorRevision": REVISION,
               "fixtureDigest": sha(directory / "fixture.json"), "healthy": True,
               "checks": sorted(CONTRACT["COMMON_SCENARIO_CHECKS"] | CONTRACT["MODE_SCENARIO_CHECKS"][mode])})
        write(directory / "inventory-evidence.json",
              {"schemaVersion": 1,
               "payload": {"version": VERSION, "sourceRevision": REVISION,
                           "system": system, "digest": payloads[system]},
               "run": {"id": HEX_A, "fixtureDigest": canonical_sha(target),
                       "mode": mode},
               "inventoryDigest": HEX_A, "reviewedChangeDigest": HEX_A,
               "privateStoreHeadDigest": HEX_A,
               "componentReceipts": [{"operation": "op-fixture", "journalDigest": HEX_A,
                                      "receiptDigest": HEX_B}],
               "finalObservation": {"complete": True},
               "coverage": {"complete": True, "resultDigest": sha(root / "coverage.json")},
               "tools": {"operator": {"revision": REVISION}}})

    if len(sys.argv) == 3 and sys.argv[1] == "--write-fixture":
        shutil.copytree(root, Path(sys.argv[2]))
        print("Wrote synthetic complete release-index inputs")
        raise SystemExit(0)

    run(root, True)
    index = read(root / "index.json")
    assert index["candidate"]["sourceRevision"] == REVISION
    assert {entry["system"] for entry in index["nativeSystems"]} == set(SYSTEMS)
    assert {entry["mode"] for entry in index["scenarios"]} == {"local", "cloud"}
    original = (root / "index.json").read_bytes()
    run(root, True)
    assert (root / "index.json").read_bytes() == original

    cloud_evidence = root / "cloud/inventory-evidence.json"
    cloud_original = cloud_evidence.read_bytes()
    cloud_evidence.unlink()
    run(root, False, "missing or linked evidence input")
    cloud_evidence.write_bytes(cloud_original)

    native_output = root / "native/nix-output-x86_64-linux.json"
    native_original = native_output.read_bytes()
    changed = read(native_output)
    changed["revision"] = "stale-revision"
    write(native_output, changed)
    run(root, False, "native output is missing or stale")
    native_output.write_bytes(native_original)

    coverage_path = root / "coverage.json"
    coverage_original = coverage_path.read_bytes()
    changed = read(coverage_path)
    changed["pending"] = ["missing-route"]
    write(coverage_path, changed)
    run(root, False, "command coverage is incomplete or stale")
    coverage_path.write_bytes(coverage_original)

    changed = read(coverage_path)
    changed["deferredRoutes"].append("CdnCommand.CdnPurge")
    write(coverage_path, changed)
    run(root, False, "supported/deferred release contract")
    coverage_path.write_bytes(coverage_original)

    changed = read(coverage_path)
    del changed["recoveryOnlyRoutes"]
    write(coverage_path, changed)
    run(root, False, "supported/deferred release contract")
    coverage_path.write_bytes(coverage_original)

    health_path = root / "cloud/cloud-health.json"
    health_original = health_path.read_bytes()
    fixture_path = root / "cloud/fixture.json"
    fixture_original = fixture_path.read_bytes()
    fixture_path.unlink()
    run(root, False, "missing or linked evidence input")
    fixture_path.write_bytes(fixture_original)
    changed = read(fixture_path)
    changed["description"] = "different fixture, same target"
    write(fixture_path, changed)
    run(root, False, "health differs from the saved fixture definition")
    fixture_path.write_bytes(fixture_original)
    for missing in ("redis-backup-restore", "source-unavailable-recovery", "google-cdn"):
        changed = read(health_path)
        changed["checks"].remove(missing)
        write(health_path, changed)
        run(root, False, "lacks required supported assertions")
        health_path.write_bytes(health_original)

    local_evidence = root / "local/inventory-evidence.json"
    local_original = local_evidence.read_bytes()
    changed = read(local_evidence)
    changed["privateCredential"] = "must-never-be-public"
    write(local_evidence, changed)
    run(root, False, "sensitive public evidence key")
    local_evidence.write_bytes(local_original)

    local_target = root / "local/target.json"
    changed = read(local_target)
    changed["context"] = "different"
    write(local_target, changed)
    run(root, False, "health evidence is missing or stale")

print("complete inventory release index and refusal tests passed")
