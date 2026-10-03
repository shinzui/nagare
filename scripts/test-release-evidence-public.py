#!/usr/bin/env python3
"""Verify public release review rejects missing or dishonest inventory proof.

Uses an isolated Git repository and synthetic provider-free evidence. No forge
request, product tag, or publication is made.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--nagarectl", type=Path, required=True)
options = parser.parse_args()


def write(path, value):
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


with tempfile.TemporaryDirectory(prefix="mp23-release-public-") as temporary:
    root = Path(temporary)
    source = root / "git"
    source.mkdir()
    for arguments in (["init", "-q"], ["config", "user.name", "Release fixture"],
                      ["config", "user.email", "release@example.invalid"]):
        subprocess.run(["git", *arguments], cwd=source, check=True)
    (source / "fixture.txt").write_text("synthetic release\n")
    subprocess.run(["git", "add", "fixture.txt"], cwd=source, check=True)
    subprocess.run(["git", "-c", "commit.gpgsign=false", "commit", "-qm", "test: seed isolated release"], cwd=source, check=True)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    version = read(REPO / "release.json")["platformVersion"]
    subprocess.run(["git", "-c", "tag.gpgsign=false", "tag", "-a", "v" + version, "-m", "fixture"], cwd=source, check=True)
    evidence = root / "evidence"
    subprocess.run(["python3", str(REPO / "scripts/test-inventory-release-index.py"), "--write-fixture", str(evidence)], check=True, capture_output=True)
    coverage = read(evidence / "coverage.json")
    coverage["sourceRevision"] = revision
    write(evidence / "coverage.json", coverage)
    manifest = read(evidence / "nagare-release-0.4.0.json")
    manifest.update(version=version, revision=revision, tag="v" + version)
    for system in manifest["systems"]:
        for prefix in ["nix-output", "clone-free"]:
            path = evidence / "native" / f"{prefix}-{system}.json"
            value = read(path)
            value.update(version=version, revision=revision)
            write(path, value)
        directory = evidence / "native" / system
        directory.mkdir()
        write(directory / f"nagare-release-{version}.json", dict(manifest, payloadDigest=manifest["payloadDigests"][system]))
        (directory / f"nagare-v{version}.md").write_text("# Synthetic release fixture\n")
    for mode in ["local", "cloud"]:
        path = evidence / mode / "inventory-evidence.json"
        value = read(path)
        value["payload"].update(version=version, sourceRevision=revision)
        value["tools"]["operator"]["revision"] = revision
        value["coverage"]["resultDigest"] = digest(evidence / "coverage.json")
        write(path, value)
        path = evidence / mode / f"{mode}-health.json"
        value = read(path)
        value["operatorRevision"] = revision
        for record in value["assertions"]:
            record["operatorRevision"] = revision
        write(path, value)
    output = root / "assets"
    subprocess.run(["bash", str(REPO / "scripts/assemble-release.sh"), "--version", version,
                    "--input-root", str(evidence / "native"), "--inventory-evidence", str(evidence),
                    "--output-dir", str(output)], check=True, capture_output=True)
    # Any accidental provider request fails; review must remain entirely local.
    bins = root / "bin"
    bins.mkdir()
    gh = bins / "gh"
    gh.write_text("#!/bin/sh\necho unexpected-provider-request >&2\nexit 97\n")
    gh.chmod(0o755)
    environment = dict(os.environ, PATH=str(bins) + os.pathsep + os.environ["PATH"])
    command = [str(options.nagarectl.absolute()), "release", "publish", "--repo", "fixture/release",
               "--version", version, "--assets", str(output)]

    def run(success, message):
        result = subprocess.run(command, cwd=source, env=environment, capture_output=True, text=True, timeout=30)
        assert (result.returncode == 0) == success, (result.stdout, result.stderr)
        assert message in result.stdout + result.stderr, (result.stdout, result.stderr)
        assert "unexpected-provider-request" not in result.stderr

    def sums():
        (output / "SHA256SUMS").write_text("".join(f"{digest(path)}  {path.name}\n" for path in sorted(output.iterdir()) if path.name != "SHA256SUMS"))

    run(True, "Review only")
    index_path = output / f"nagare-inventory-evidence-v{version}.json"
    original_index = index_path.read_bytes()
    index_path.unlink()
    run(False, "missing required release asset")
    index_path.write_bytes(original_index)
    health_path = output / "inventory-cloud-health.json"
    original_health = health_path.read_bytes()
    changed = read(health_path)
    changed["checks"].remove("redis-backup-restore")
    write(health_path, changed)
    changed_index = read(index_path)
    cloud = next(item for item in changed_index["scenarios"] if item["mode"] == "cloud")
    cloud["healthDigest"] = digest(health_path)
    write(index_path, changed_index)
    sums()
    run(False, "lacks required supported assertions")
    health_path.write_bytes(original_health)
    index_path.write_bytes(original_index)
    # A required name whose bound record was removed is refused by the
    # validator itself, even with a recomputed index and sums.
    changed = read(health_path)
    changed["assertions"] = [item for item in changed["assertions"] if item["name"] != "google-cdn"]
    write(health_path, changed)
    changed_index = read(index_path)
    cloud = next(item for item in changed_index["scenarios"] if item["mode"] == "cloud")
    cloud["healthDigest"] = digest(health_path)
    write(index_path, changed_index)
    sums()
    run(False, "lacks bound assertion records")
    health_path.write_bytes(original_health)
    index_path.write_bytes(original_index)
    # Recompute the public index and sums so the validator must compare the
    # health's declared fixture with the separately shipped definition.
    fixture_path = output / "inventory-cloud-fixture.json"
    original_fixture = fixture_path.read_bytes()
    changed = read(fixture_path)
    changed["description"] = "another fixture with the same context"
    write(fixture_path, changed)
    changed_index = read(index_path)
    cloud = next(item for item in changed_index["scenarios"] if item["mode"] == "cloud")
    cloud["fixtureDigest"] = digest(fixture_path)
    write(index_path, changed_index)
    sums()
    run(False, "release evidence digest differs: inventory-cloud-fixture.json")
    fixture_path.write_bytes(original_fixture)
    index_path.write_bytes(original_index)
    target_path = output / "inventory-local-target.json"
    original_target = target_path.read_bytes()
    changed = read(target_path)
    changed["context"] = "foreign-context"
    write(target_path, changed)
    sums()
    run(False, "release evidence digest differs")
    target_path.write_bytes(original_target)
    coverage_path = output / "inventory-coverage.json"
    original_coverage = coverage_path.read_bytes()
    changed = read(coverage_path)
    changed["deferredRoutes"].append("CdnCommand.CdnPurge")
    write(coverage_path, changed)
    changed_index = read(index_path)
    changed_index["coverageDigest"] = digest(coverage_path)
    write(index_path, changed_index)
    sums()
    run(False, "changes the supported contract")
    coverage_path.write_bytes(original_coverage)
    index_path.write_bytes(original_index)
    sums()
    run(True, "Review only")
print("public release review accepts complete proof and refuses missing, stale and narrowed evidence")
