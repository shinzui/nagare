#!/usr/bin/env python3
"""Record release scenario assertions as they pass and fold them into health.

A scenario run (EP-155 local, EP-156 cloud) records each supported assertion
when, and only when, it has observed that assertion pass:

  scripts/scenario-assertions.py record --evidence-dir DIR --mode local \
      --name redis-backup-restore --summary "isolated restore returned the seeded keys" \
      --evidence steps/redis-restore/result.json [--evidence ...]

The record is create-only (assertions/<name>.json), bound to the run's context,
cluster, operator revision and fixture digest from the plan-time health record,
and lists the SHA-256 of each public evidence file inside DIR. After the runner's
verify phase, finalize folds every record into <mode>-health.json:

  scripts/scenario-assertions.py finalize --evidence-dir DIR --mode local

Finalize refuses while any required assertion is missing, so a partial run can
never produce acceptable health. Both commands reuse the release index
assembler's validation, which the release gate applies again at assembly.
"""

import argparse
import datetime
import json
import os
import runpy
import tempfile
from pathlib import Path

GATE = runpy.run_path(str(Path(__file__).with_name("assemble-inventory-release-index.py")))
fail = GATE["fail"]
require = GATE["require"]
read_json = GATE["read_json"]
digest = GATE["digest"]
reject_sensitive = GATE["reject_sensitive"]
required_checks = GATE["required_checks"]
evidence_file = GATE["evidence_file"]
validate_assertion = GATE["validate_assertion"]
validate_assertions = GATE["validate_assertions"]
BINDING_KEYS = GATE["BINDING_KEYS"]


def encode(value: dict) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def preflight_health(directory: Path, mode: str) -> tuple:
    require(not directory.is_symlink() and directory.is_dir(),
            f"evidence directory is missing or linked: {directory}")
    health_path = directory / f"{mode}-health.json"
    health = read_json(health_path)
    require(health.get("schemaVersion") == 1 and health.get("mode") == mode
            and health.get("healthy") is True
            and all(isinstance(health.get(key), str) and health[key] for key in BINDING_KEYS)
            and health["fixtureDigest"] == digest(directory / "fixture.json"),
            f"{mode} plan-time health is missing, unhealthy or differs from fixture.json")
    return health_path, health


def check_public(path: Path, relative: str) -> None:
    """Evidence becomes public release material; refuse secret-shaped content."""
    raw = path.read_bytes()
    if relative.endswith(".json"):
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            fail(f"JSON evidence is invalid: {relative}")
        reject_sensitive(value, f"evidence.{relative}")
    else:
        try:
            reject_sensitive(raw.decode("utf-8"), f"evidence.{relative}")
        except UnicodeError:
            fail(f"evidence must be UTF-8 text or JSON: {relative}")


def write_exclusive(path: Path, data: bytes) -> bool:
    """Create path with data; True if created, False if identical bytes exist."""
    path.parent.mkdir(mode=0o700, exist_ok=True)
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        return False
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)
    return True


def record(arguments: argparse.Namespace) -> None:
    directory = arguments.evidence_dir.resolve()
    mode = arguments.mode
    _, health = preflight_health(directory, mode)
    require(arguments.name in required_checks(mode),
            f"{arguments.name} is not a supported {mode} scenario assertion")
    evidence = []
    for relative in arguments.evidence:
        path = evidence_file(directory, relative)
        check_public(path, relative)
        evidence.append({"path": relative, "sha256": digest(path)})
    require(len({item["path"] for item in evidence}) == len(evidence), "evidence repeats a path")
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    value = {"schemaVersion": 1, "name": arguments.name, "mode": mode,
             **{key: health[key] for key in BINDING_KEYS},
             "passed": True, "recordedAt": now, "summary": arguments.summary,
             "evidence": sorted(evidence, key=lambda item: item["path"])}
    validate_assertion(value, health, directory, mode)
    target = directory / "assertions" / f"{arguments.name}.json"
    if write_exclusive(target, encode(value)):
        print(f"Recorded {mode} assertion {arguments.name}: {target}")
        return
    existing = read_json(target)
    same = {key: existing.get(key) for key in value if key != "recordedAt"} == \
        {key: value[key] for key in value if key != "recordedAt"}
    require(same, f"assertion {arguments.name} is already recorded with different evidence; "
                  "a changed result needs a new run, not an overwrite")
    print(f"Assertion {arguments.name} is already recorded with the same evidence")


def finalize(arguments: argparse.Namespace) -> None:
    directory = arguments.evidence_dir.resolve()
    mode = arguments.mode
    health_path, health = preflight_health(directory, mode)
    if "assertions" in health:
        validate_assertions(health, directory, mode)
        preflight = {key: value for key, value in health.items() if key not in ("assertions", "preflightChecks")}
        preflight["checks"] = health["preflightChecks"]
    else:
        preflight = health
    assertion_dir = directory / "assertions"
    require(assertion_dir.is_dir() and not assertion_dir.is_symlink(),
            f"{mode} run has recorded no scenario assertions")
    records = []
    for path in sorted(assertion_dir.iterdir()):
        require(path.suffix == ".json" and path.is_file() and not path.is_symlink(),
                f"unexpected entry in assertions directory: {path.name}")
        value = read_json(path)
        name = validate_assertion(value, preflight, directory, mode)
        require(path.name == f"{name}.json", f"assertion file name differs from its record: {path.name}")
        records.append(value)
    names = {item["name"] for item in records}
    missing = sorted(required_checks(mode) - names)
    require(not missing, f"{mode} run lacks required assertions: {', '.join(missing)}")
    final = dict(preflight)
    final["preflightChecks"] = preflight["checks"]
    final["checks"] = sorted(set(preflight["checks"]) | names)
    final["assertions"] = sorted(records, key=lambda item: item["name"])
    validate_assertions(final, directory, mode)
    data = encode(final)
    if health_path.read_bytes() == data:
        print(f"{mode} health is already finalized with {len(records)} assertions")
        return
    require("assertions" not in health, f"{mode} health was finalized with different assertions")
    with tempfile.NamedTemporaryFile(prefix=f".{mode}-health.", dir=directory, delete=False) as handle:
        handle.write(data)
        staging = Path(handle.name)
    os.chmod(staging, 0o644)
    os.replace(staging, health_path)
    print(f"Finalized {health_path} with {len(records)} recorded assertions")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("record", "finalize"):
        command = commands.add_parser(name)
        command.add_argument("--evidence-dir", required=True, type=Path)
        command.add_argument("--mode", required=True, choices=["local", "cloud"])
        if name == "record":
            command.add_argument("--name", required=True)
            command.add_argument("--summary", required=True)
            command.add_argument("--evidence", required=True, action="append")
    arguments = parser.parse_args()
    (record if arguments.command == "record" else finalize)(arguments)


if __name__ == "__main__":
    main()
