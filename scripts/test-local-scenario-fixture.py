#!/usr/bin/env python3
"""Validate the checked-in MP-23 local scenario fixture (EP-155, B5).

The fixture is copied byte for byte into every local evidence directory as
fixture.json, so it must satisfy the release gate itself: no sensitive keys or
values, and exactly the scenario check names the gate requires for local mode.
It must also keep the health contract the local runner reads, and every app
config it names must exist. With --check-configs the typed Application
configs are evaluated offline through `nagarectl app check`; this needs
NAGARECTL_BIN (or nagarectl on PATH) and NAGARE_GHC_ENVIRONMENT.
"""

import argparse
import json
import os
import runpy
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURE_DIR = ROOT / "fixtures" / "inventory-release" / "local"
FIXTURE = FIXTURE_DIR / "scenario.json"
RUNNER = ROOT / "scripts" / "rehearse-local-inventory-release.sh"
GATE = runpy.run_path(str(ROOT / "scripts" / "assemble-inventory-release-index.py"))
HEALTH_NAMES = ("knativeNamespace", "knativeWebhook", "objectStoreNamespace",
                "objectStoreDeployment", "objectStoreService", "objectStoreBucketJob")
ENGINES = {"postgresql", "redis", "clickhouse", "volume"}


def check(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"local scenario fixture: {message}")


def validate(fixture: dict) -> dict:
    # The local runner's health contract (rehearse-local-inventory-release.sh).
    check(fixture.get("schemaVersion") == 1 and fixture.get("mode") == "local",
          "schemaVersion must be 1 and mode local")
    check(fixture.get("clusterPrefix") == "k3d-", "clusterPrefix must be k3d-")
    check(all(isinstance(fixture.get(name), str) and fixture[name]
              and all(c.islower() or c.isdigit() or c == "-" for c in fixture[name])
              for name in HEALTH_NAMES), "health object names must be DNS labels")
    check(fixture.get("registryUrl") == "http://k3d-registry.localhost:5000/v2/",
          "registryUrl must name the local k3d registry")
    check('local/scenario.json"' in RUNNER.read_text(), "the local runner must copy scenario.json")

    # The release gate copies this file into public evidence.
    GATE["reject_sensitive"](fixture, "fixture")

    scenario = fixture.get("scenario")
    check(isinstance(scenario, dict), "scenario section is missing")
    steps = scenario.get("steps", [])
    step_ids = [step.get("id") for step in steps]
    check(len(step_ids) == len(set(step_ids)) and all(step_ids), "step ids must be unique")
    check(all(step.get("summary") and step.get("commands") for step in steps),
          "every step needs a summary and commands")

    assertions = scenario.get("assertions", [])
    names = [assertion.get("name") for assertion in assertions]
    required = GATE["required_checks"]("local")
    check(len(names) == len(set(names)), "an assertion name is listed twice")
    check(set(names) == required,
          f"assertions must equal the gate's local checks; missing {sorted(required - set(names))}, "
          f"extra {sorted(set(names) - required)}")
    for assertion in assertions:
        check(assertion.get("steps") and set(assertion["steps"]) <= set(step_ids),
              f"assertion {assertion.get('name')} names an unknown step")

    stores = scenario.get("dataStores", [])
    check({store.get("engine") for store in stores} == ENGINES, "every supported store needs seed content")
    check(all(store.get("seed") and store.get("afterBackup") for store in stores),
          "every store needs seeded content and a later change for isolated restore")

    channels = {(channel.get("scope"), channel.get("source")) for channel in scenario.get("channels", [])}
    check({("runtime", "literal"), ("preview", "literal"), ("runtime", "encrypted-store")} <= channels,
          "runtime, preview and encrypted-store channels are required")

    configs = []
    for application in scenario.get("applications", []):
        config = FIXTURE_DIR / application["config"]
        context = FIXTURE_DIR / application["buildContext"]
        check(config.is_file(), f"missing application config {application['config']}")
        check((context / "Dockerfile").is_file(), f"missing Dockerfile in {application['buildContext']}")
        configs.append(config)
    check({application.get("id") for application in scenario.get("applications", [])} == {"a", "b"},
          "applications A and B are required")
    check(any(application.get("route", {}).get("access") == "require-login"
              for application in scenario["applications"]), "one application must be protected")
    collision = FIXTURE_DIR / scenario["collisionVariant"]["config"]
    check(collision.is_file(), "missing collision variant config")
    configs.append(collision)
    site = scenario.get("site", {})
    check((FIXTURE_DIR / site.get("config", "")).is_file()
          and (FIXTURE_DIR / site.get("projectDir", "") / "public" / "index.html").is_file(),
          "missing site config or its public directory")
    check(scenario.get("broker", {}).get("topics"), "a broker topic is required")
    check(scenario.get("jobs", {}).get("scheduled") and scenario["jobs"].get("oneOff"),
          "scheduled and one-off Jobs are required")
    check(scenario.get("rename", {}).get("source") != scenario.get("rename", {}).get("destination"),
          "the rename needs distinct names")
    return {"configs": configs}


def check_configs(configs: list) -> None:
    binary = os.environ.get("NAGARECTL_BIN", "nagarectl")
    environment = dict(os.environ, NAGARE_BASE_DOMAIN="127-0-0-1.sslip.io")
    check("NAGARE_GHC_ENVIRONMENT" in environment, "--check-configs needs NAGARE_GHC_ENVIRONMENT")
    for config in configs:
        result = subprocess.run(
            [binary, "app", "check", "--file", str(config.relative_to(config.parent.parent))],
            cwd=config.parent.parent, env=environment, capture_output=True, text=True, check=False)
        check(result.returncode == 0, f"app check failed for {config}: {result.stderr.strip()}")
        summary = json.loads(result.stdout)
        check(summary.get("kind") == "application", f"{config} is not a typed Application")
        print(f"app check: {summary['name']} databases={summary['databases']} brokers={summary['brokers']}")


def self_test(fixture: dict) -> None:
    """Each gate rule must refuse a fixture that breaks it."""
    def refused(mutate) -> bool:
        broken = json.loads(json.dumps(fixture))
        mutate(broken)
        try:
            validate(broken)
        except SystemExit:
            return True
        return False

    check(refused(lambda f: f["scenario"]["assertions"].pop()), "a missing check name was accepted")
    check(refused(lambda f: f["scenario"].update({"secretValue": "x"})), "a sensitive key was accepted")
    check(refused(lambda f: f.update({"mode": "cloud"})), "a cloud fixture was accepted")
    check(refused(lambda f: f["scenario"]["dataStores"].pop()), "a missing store was accepted")
    check(refused(lambda f: f.update({"registryUrl": "http://example/v2/"})), "a foreign registry was accepted")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-configs", action="store_true")
    args = parser.parse_args()
    fixture = json.loads(FIXTURE.read_text())
    result = validate(fixture)
    self_test(fixture)
    if args.check_configs:
        check_configs(result["configs"])
    print("local scenario fixture: health contract, gate check names, stores, channels and configs validated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
