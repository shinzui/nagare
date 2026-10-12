#!/usr/bin/env python3
"""Verify the public release review accepts a complete proof and refuses a missing, foreign or
failed transition rehearsal record (EP-172).

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


with tempfile.TemporaryDirectory(prefix="nagare-release-public-") as temporary:
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
    metadata = read(REPO / "release.json")
    version = metadata["platformVersion"]
    systems = metadata["supportedSystems"]
    subprocess.run(["git", "-c", "tag.gpgsign=false", "tag", "-a", "v" + version, "-m", "fixture"], cwd=source, check=True)
    native = root / "native"
    manifest = {"version": version, "tag": "v" + version, "revision": revision, "consistent": True, "systems": systems}
    for system in systems:
        directory = native / system
        directory.mkdir(parents=True)
        payload = "sha256-platform-" + system
        write(directory / f"nagare-release-{version}.json", dict(manifest, payloadDigest=payload))
        (directory / f"nagare-v{version}.md").write_text("# Synthetic release fixture\n")
        write(directory / f"nix-output-{system}.json",
              {"version": version, "revision": revision, "system": system,
               "outputs": {"nagarectl": {"narHash": "sha256-cli", "narSize": 1},
                           "nagare-platform": {"narHash": payload, "narSize": 2}}})
        write(directory / f"clone-free-{system}.json",
              {"version": version, "revision": revision, "system": system, "supportedSystems": systems,
               "cloneFree": True, "checks": ["version", "context", "typed-config", "inventory-compile",
                                             "payload", "operator-recipe"]})
    identity = {"version": version, "revision": revision}
    rehearsal = root / "transition-rehearsal.json"
    write(rehearsal, {
        "schemaVersion": 1, "mode": "local", "context": "transition",
        "source": {"version": metadata["transitionsFrom"][0], "revision": "a" * 40},
        "candidate": identity,
        "bootstrap": {"reviews": 3}, "transition": {"reviews": 3, "operations": 1},
        "sentinel": {"seeded": "transition fixture", "readBack": "transition fixture"},
        "platform": {"identities": {"cli": identity, "payload": identity, "cluster": identity,
                                    "context": {"version": version, "revision": None},
                                    "host": {"version": None, "revision": None}}},
        "inventory": {"activeTransaction": None, "transactionStatus": None, "observationComplete": True},
        "replan": {"operations": 0, "reaccepts": 0}})
    output = root / "assets"
    subprocess.run(["bash", str(REPO / "scripts/assemble-release.sh"), "--version", version,
                    "--input-root", str(native), "--transition-rehearsal", str(rehearsal),
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

    def changed(adjust, message):
        value = json.loads(original)
        adjust(value)
        write(record, value)
        sums()
        run(False, message)

    run(True, "Review only")
    record = output / f"nagare-transition-rehearsal-v{version}.json"
    original = record.read_bytes()
    record.unlink()
    run(False, "missing required release asset")
    record.write_bytes(original)
    # Recomputed sums do not make a foreign or failed rehearsal acceptable.
    changed(lambda value: value["candidate"].update(revision="0" * 40), "belongs to another candidate")
    changed(lambda value: value["source"].update(version="0.1.0"), "does not accept")
    changed(lambda value: value["sentinel"].update(readBack="another row"), "read the seeded data back changed")
    changed(lambda value: value["replan"].update(operations=1), "replan is not converged")
    changed(lambda value: value["inventory"].update(activeTransaction="tx-1"), "ended with an open transaction")
    record.write_bytes(original)
    sums()
    run(True, "Review only")
print("public release review accepts a complete proof and refuses a missing, foreign or failed transition rehearsal")
