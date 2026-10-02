#!/usr/bin/env python3
"""Bind both native systems and both inventory scenarios to one release candidate."""

import argparse
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path


HEX = re.compile(r"^[0-9a-f]{64}$")
DEFERRED_ROUTES = ["DbCommand.DbPruneScheduledBackups", "DbCommand.DbRestore.--into-live",
                   "DbCommand.DbShell", "StorageCommand.StorageRestore.--into-live"]
RECOVERY_ONLY_ROUTES = ["DbCommand.DbRecoverScheduledPrune"]
COMMON_SCENARIO_CHECKS = {
    "collision-refusal", "adoption", "drift-classification", "convergence-noop-removal",
    "independent-scope-preservation", "secret-read-refusal", "interrupted-recovery",
    "postgresql-backup-restore", "redis-backup-restore", "clickhouse-backup-restore",
    "volume-backup-restore", "source-unavailable-recovery", "backup-freshness",
    "retained-data", "access-grant-revoke",
}
MODE_SCENARIO_CHECKS = {
    "local": {"retained-postgresql-rename"},
    "cloud": {"shared-history-takeover", "google-cdn"},
}
SENSITIVE_KEY = re.compile(r"password|credential|access.?token|private.?key|secret", re.I)


def fail(message: str) -> None:
    raise SystemExit(f"inventory release index: {message}")


def read_json(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        fail(f"missing or linked evidence input: {path}")
    try:
        result = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"invalid JSON evidence input {path}: {error}")
    if not isinstance(result, dict):
        fail(f"evidence input is not an object: {path}")
    return result


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_digest(value: dict) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def is_hex(value: object) -> bool:
    return isinstance(value, str) and HEX.fullmatch(value) is not None


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def reject_sensitive(value: object, path: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            require(not SENSITIVE_KEY.search(key), f"sensitive public evidence key: {path}.{key}")
            reject_sensitive(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_sensitive(child, f"{path}[{index}]")
    elif isinstance(value, str):
        require("must-never-be-public" not in value and "ENC[" not in value
                and "-----BEGIN PRIVATE KEY-----" not in value,
                f"sensitive public evidence value: {path}")


def scenario(mode: str, directory: Path, version: str, revision: str,
             payloads: dict, coverage_digest: str) -> dict:
    target_path = directory / "target.json"
    health_path = directory / f"{mode}-health.json"
    fixture_path = directory / "fixture.json"
    evidence_path = directory / "inventory-evidence.json"
    target = read_json(target_path)
    health = read_json(health_path)
    fixture = read_json(fixture_path)
    evidence = read_json(evidence_path)
    reject_sensitive(target, f"{mode}.target")
    reject_sensitive(health, f"{mode}.health")
    reject_sensitive(fixture, f"{mode}.fixture")
    require(fixture.get("schemaVersion") == 1 and fixture.get("mode") == mode,
            f"{mode} fixture has wrong schema or mode")
    reject_sensitive(evidence, f"{mode}.evidence")
    require(target.get("schemaVersion") == 1 and target.get("mode") == mode,
            f"{mode} target has wrong schema or mode")
    require(all(isinstance(target.get(key), str) and target[key] for key in
                ("context", "kubeContext", "expectedCluster")),
            f"{mode} target lacks exact context or cluster")
    require((mode == "cloud" and isinstance(target.get("expectedProject"), str)
             and bool(target["expectedProject"])) or
            (mode == "local" and target.get("expectedProject") is None),
            f"{mode} target has wrong project binding")
    require(health.get("schemaVersion") == 1 and health.get("mode") == mode
            and health.get("healthy") is True and health.get("context") == target["context"]
            and health.get("cluster") == target["expectedCluster"]
            and health.get("operatorRevision") == revision
            and is_hex(health.get("fixtureDigest"))
            and isinstance(health.get("checks"), list) and bool(health["checks"]),
            f"{mode} health evidence is missing or stale")
    require(health["fixtureDigest"] == digest(fixture_path),
            f"{mode} health differs from the saved fixture definition")
    require(all(isinstance(check, str) for check in health["checks"])
            and COMMON_SCENARIO_CHECKS | MODE_SCENARIO_CHECKS[mode] <= set(health["checks"]),
            f"{mode} health evidence lacks required supported assertions")
    payload = evidence.get("payload", {})
    run = evidence.get("run", {})
    require(evidence.get("schemaVersion") == 1 and payload.get("version") == version
            and payload.get("sourceRevision") == revision
            and payload.get("system") in payloads
            and payload.get("digest") == payloads.get(payload.get("system")),
            f"{mode} inventory evidence belongs to another candidate")
    require(run.get("mode") == mode and is_hex(run.get("id"))
            and run.get("fixtureDigest") == canonical_digest(target),
            f"{mode} inventory run differs from the saved target")
    require(is_hex(evidence.get("inventoryDigest"))
            and is_hex(evidence.get("reviewedChangeDigest"))
            and is_hex(evidence.get("privateStoreHeadDigest"))
            and isinstance(evidence.get("componentReceipts"), list)
            and bool(evidence["componentReceipts"])
            and all(is_hex(item.get("journalDigest")) and is_hex(item.get("receiptDigest"))
                    and isinstance(item.get("operation"), str) and item["operation"]
                    for item in evidence["componentReceipts"]),
            f"{mode} inventory evidence lacks committed receipts")
    require(evidence.get("finalObservation", {}).get("complete") is True
            and evidence.get("coverage", {}).get("complete") is True
            and evidence["coverage"].get("resultDigest") == coverage_digest,
            f"{mode} final observation or coverage is incomplete")
    require(evidence.get("tools", {}).get("operator", {}).get("revision") == revision,
            f"{mode} operator revision differs from the candidate")
    return {
        "mode": mode,
        "system": payload["system"],
        "context": target["context"],
        "kubeContext": target["kubeContext"],
        "cluster": target["expectedCluster"],
        "project": target["expectedProject"],
        "runId": run["id"],
        "targetDigest": digest(target_path),
        "healthDigest": digest(health_path),
        "fixtureDigest": digest(fixture_path),
        "evidenceDigest": digest(evidence_path),
        "receiptCount": len(evidence["componentReceipts"]),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("release-metadata", "release-manifest", "native-dir", "coverage-result",
                 "local-dir", "cloud-dir", "output"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    args = parser.parse_args()
    metadata = read_json(args.release_metadata)
    release = read_json(args.release_manifest)
    coverage = read_json(args.coverage_result)
    version = release.get("version")
    revision = release.get("revision")
    systems = release.get("systems")
    payloads = release.get("payloadDigests")
    require(release.get("consistent") is True and isinstance(version, str) and bool(version)
            and isinstance(revision, str) and bool(revision)
            and isinstance(systems, list) and bool(systems)
            and all(isinstance(item, str) and item for item in systems)
            and len(systems) == len(set(systems)) and isinstance(payloads, dict)
            and set(payloads) == set(systems)
            and all(isinstance(value, str) and value.startswith("sha256-")
                    for value in payloads.values()),
            "release manifest lacks a complete native candidate")
    require(metadata.get("platformVersion") == version
            and set(metadata.get("supportedSystems", [])) == set(systems)
            and len(metadata.get("supportedSystems", [])) == len(systems),
            "release candidate differs from release.json supported systems")
    require(coverage.get("schemaVersion") == 1 and coverage.get("complete") is True
            and coverage.get("dirty") is False and coverage.get("sourceRevision") == revision
            and is_hex(coverage.get("candidateDigest"))
            and all(coverage.get(key) == [] for key in
                    ("pending", "pendingRecipes", "incompleteCatalogueRows", "errors"))
            and all(isinstance(coverage.get(key), int) and coverage[key] > 0 for key in
                    ("registeredRoutes", "recipes", "libraryCalls")),
            "command coverage is incomplete or stale")
    require(coverage.get("deferredRoutes") == DEFERRED_ROUTES
            and coverage.get("recoveryOnlyRoutes") == RECOVERY_ONLY_ROUTES,
            "command coverage changes the supported/deferred release contract")
    reject_sensitive(coverage, "coverage")
    coverage_digest = digest(args.coverage_result)
    native = []
    for system in sorted(systems):
        output_path = args.native_dir / f"nix-output-{system}.json"
        rehearsal_path = args.native_dir / f"clone-free-{system}.json"
        output = read_json(output_path)
        rehearsal = read_json(rehearsal_path)
        reject_sensitive(output, f"{system}.output")
        reject_sensitive(rehearsal, f"{system}.rehearsal")
        require(output.get("version") == version and output.get("revision") == revision
                and output.get("system") == system
                and output.get("outputs", {}).get("nagarectl", {}).get("narHash", "").startswith("sha256-")
                and output.get("outputs", {}).get("nagare-platform", {}).get("narHash") == payloads[system],
                f"native output is missing or stale for {system}")
        require(rehearsal.get("version") == version and rehearsal.get("revision") == revision
                and rehearsal.get("system") == system and rehearsal.get("cloneFree") is True
                and rehearsal.get("installedSmoke") is not True
                and set(rehearsal.get("supportedSystems", [])) == set(systems)
                and isinstance(rehearsal.get("checks"), list)
                and {"version", "context", "typed-config", "payload", "operator-recipe"}
                    <= set(rehearsal["checks"]),
                f"clone-free native rehearsal is missing or stale for {system}")
        native.append({"system": system, "payloadDigest": payloads[system],
                       "outputDigest": digest(output_path),
                       "rehearsalDigest": digest(rehearsal_path)})
    scenarios = [scenario("local", args.local_dir, version, revision, payloads, coverage_digest),
                 scenario("cloud", args.cloud_dir, version, revision, payloads, coverage_digest)]
    index = {"schemaVersion": 1,
             "candidate": {"version": version, "sourceRevision": revision,
                           "manifestDigest": digest(args.release_manifest),
                           "metadataDigest": digest(args.release_metadata)},
             "coverageDigest": coverage_digest,
             "nativeSystems": native,
             "scenarios": scenarios}
    encoded = (json.dumps(index, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".inventory-index.", dir=args.output.parent,
                                     delete=False) as temporary:
        temporary.write(encoded)
        staging = Path(temporary.name)
    try:
        if args.output.exists() or args.output.is_symlink():
            require(not args.output.is_symlink() and args.output.read_bytes() == encoded,
                    "existing index has different bytes")
        else:
            try:
                os.link(staging, args.output)
            except FileExistsError:
                require(not args.output.is_symlink() and args.output.read_bytes() == encoded,
                        "index was concurrently created with different bytes")
    finally:
        staging.unlink()
    print(f"Assembled complete inventory release index {args.output}")


if __name__ == "__main__":
    main()
