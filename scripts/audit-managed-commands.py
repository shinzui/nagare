#!/usr/bin/env python3
"""Audit the finite public mutation registry against typed CLI dispatch.

The registry is deliberately exhaustive, including read-only constructors. A new
constructor cannot be silently treated as an observation. The coverage result is
incomplete until every live route has a reviewed or accepted disposition.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "cli/nagarectl/app"
OPTIONS = CLI / "Nagare/Cli/Options.hs"
DISPATCH = CLI / "Nagare/Cli/Dispatch.hs"
CATALOGUE = ROOT / "docs/architecture/managed-resource-coverage.md"
CATALOGUE_START = "<!-- managed-command-registry:start -->"
CATALOGUE_END = "<!-- managed-command-registry:end -->"

# Route states: read (no mutation), group (nested dispatch), reviewed (shared
# inventory), bounded (a specifically constrained transport), legacy (only
# before admission), recovery (an admitted historical effect only), deferred
# (new admission refused for this release), pending (promised reviewed behavior),
# and excluded (the accepted first-release exclusion for in-place upgrades).
# Each entry is an exact constructor name; there are no wildcard exemptions.
ROUTES = {
    "Command": {
        "read": "Version InventoryStatus InventoryLegacyGuard InventoryExplain InventoryStoreStatus PlatformRoot PlatformStatusCmd PlatformGuard PlatformUpgradeStatus SiteReleases SitePreviewList AppList AppGet AppLogs DeploymentsList DeploymentsLogs ServerStatus Doctor InventoryGc",
        "group": "Host Kubeconfig Cluster Env Secret Storage Broker Db Task Worker Access ContextCmdGroup Infra Domains CdnCmd",
        "reviewed": "InventoryPlan InventoryAdopt InventoryMigrate InventoryRetire InventoryCollect InventoryApply InventoryResume InventoryRecover InventoryClose InventoryRegistryRecoveryPlan InventoryStoreMigrate PlatformBootstrapPlan PlatformBootstrapApply Deploy SiteDeploy SiteRollback SitePreviewDeploy SitePreviewDelete AppRestart AppStop AppDelete AppDeploy AppImagePlan Cleanup",
        "local": "InventoryCompile AppCheck",
        "bounded": "InventoryStoreMaterializeNative InventoryExport InventoryRestore Init",
        "retired": "PlatformStamp",
        "excluded": "PlatformAdopt PlatformRepin PlatformUpgrade PlatformUpgradeRollback PlatformUpgradeRecoverPulumi",
        "release": "ReleasePublish ReleaseCleanupStarter",
    },
    "HostCommand": {
        "read": "HostShow HostPath HostName",
        "bounded": "HostInit",
        "reviewed": "HostPlan HostApply HostPlaceAgeKey HostStart HostStop HostImagePlan",
    },
    "KubeconfigCommand": {
        "local": "KubeconfigFetch",
        "bounded": "KubeconfigRecover",
    },
    "ClusterCommand": {"read": "ClusterGuard ClusterCertificatePolicy"},
    "ContextCommand": {
        "read": "ContextList ContextCurrent ContextShow ContextGuard ContextEnv",
        "local": "ContextUse",
        "bounded": "ContextCreate ContextDelete ContextApply ContextRestore",
    },
    "InfraCommand": {
        "read": "InfraGuard",
        "reviewed": "InfraPreview InfraApply InfraDestroy",
    },
    "EnvCommand": {"read": "EnvList", "reviewed": "EnvSet EnvDelete EnvSync"},
    "SecretCommand": {"read": "SecretList", "reviewed": "SecretSet SecretDelete SecretSync"},
    "StorageCommand": {
        "read": "StorageList StorageInspect",
        "reviewed": "StorageSnapshot StorageRestore StoragePrune",
    },
    "DbCommand": {
        "read": "DbList DbGet DbVerifyEscrowedBackup",
        "local": "DbEscrowSigningKey",
        "reviewed": "DbCreate DbRename DbRestart DbDelete DbRetire DbBackup DbPruneBackup DbBackupReceipts DbManualReceipt DbDisableBackupPrune DbRestore",
        "recovery": "DbRecoverScheduledPrune",
        "deferred": "DbShell DbPruneScheduledBackups",
    },
    "BrokerCommand": {
        "read": "BrokerList BrokerGet",
        "reviewed": "BrokerCreate BrokerRestart BrokerDelete BrokerRetire",
    },
    "TaskCommand": {
        "read": "TaskList TaskLogs",
        "reviewed": "TaskRun TaskDelete",
    },
    "WorkerCommand": {"reviewed": "WorkerDeploy WorkerDelete"},
    "AccessCommand": {
        "read": "AccessList",
        "group": "AccessPortal",
        "reviewed": "AccessGrant AccessRevoke",
    },
    "PortalCommand": {"read": "PortalShow", "reviewed": "PortalSync"},
    "DomainsCommand": {"read": "DomainsList DomainsCheck"},
    "CdnCommand": {
        "read": "CdnList CdnStatus",
        "reviewed": "CdnPurge CdnDisable",
    },
}

# The operator approved exactly these additional admission exclusions for this
# release. Variants share a constructor with supported isolated restore.
AUTHORIZED_DEFERRED = {
    "DbCommand.DbShell",
    "DbCommand.DbPruneScheduledBackups",
    "DbCommand.DbRestore.--into-live",
    "StorageCommand.StorageRestore.--into-live",
}
DEFERRED_VARIANTS = {
    "DbCommand.DbRestore.--into-live",
    "StorageCommand.StorageRestore.--into-live",
}
AUTHORIZED_RECOVERY_ONLY = {"DbCommand.DbRecoverScheduledPrune"}

# These are independently callable consumers of the CLI or provider transports.
# A missing path or changed invocation is an audit failure, so packaged recipes
# and library callers cannot disappear from the review unnoticed.
ENTRYPOINTS = {
    "cli/nagarectl/nagared/Main.hs": ("reviewedSiteArgs", "submitReviewedSite"),
    "scripts/local-smoke.sh": ("nagarectl app image-plan", "--image-resource", "nagarectl storage snapshot", "--snapshot-id", "nagarectl storage restore", "--restore-id", "nagarectl inventory apply", "verify_restored_sentinel"),
    "scripts/live-smoke.sh": ("nagarectl app image-plan", "--image-resource", "nagarectl storage snapshot", "--snapshot-id", "nagarectl storage restore", "--restore-id", "nagarectl inventory apply", "verify_restored_sentinel"),
    "scripts/lib/smoke-readback.sh": ("NAGARE_VOLUME_RESTORE_FILE", "NAGARE_VOLUME_RESTORE_MANIFEST", "logs \"job/${job}\" -c restore"),
    "scripts/run-reviewed-bootstrap.sh": ("platform bootstrap plan", "platform bootstrap apply"),
    "scripts/host-switch.sh": ("NAGARE_INVENTORY_ADAPTER_CHILD",),
    "scripts/upload-images.sh": ("NAGARE_INVENTORY_ADAPTER_CHILD", "inventory guard-legacy upload-images"),
    "scripts/install-net-certmanager-controller.sh": ("inventory guard-legacy install-net-certmanager-controller",),
    # Delegated operator build infrastructure; never inventory-managed.
    "scripts/setup-nix-builder.sh": ("NAGARE_INVENTORY_ADAPTER_CHILD",),
    "scripts/nix-builder-proxy.sh": ("--read-only",),
    "scripts/vm-power.sh": ("NAGARE_INVENTORY_ADAPTER_CHILD",),
    "scripts/iap-ssh.sh": ("gcloud",),
    "scripts/inventory-host-transport.sh": ("NAGARE_INVENTORY",),
    "scripts/inventory-artifact-transport.sh": ("NAGARE_INVENTORY",),
    "scripts/inventory-cache-transport.sh": ("NAGARE_INVENTORY",),
    "justfile": ("vm-stop *args:", "vm-start *args:", 'host-switch review="":', "cluster-bootstrap:", "local-bootstrap:", "smoke:", "local-smoke:", "nagarectl inventory guard-legacy local-down"),
}

SMOKE_BYPASS_PATTERNS = (
    r"\bkubectl\b[^\n]*\bdelete\s+pvc\b",
    r"\bgsutil\s+rm\b",
    r"\bmc\s+rm\b",
    r"\bnagarectl\s+app\s+delete\b[^\n]*--yes\b",
)

RECIPE_SCRIPTS = {
    "scripts/host-switch.sh",
    "scripts/check-haskell-style.sh",
    "scripts/iap-ssh.sh",
    "scripts/live-smoke.sh",
    "scripts/live-test.sh",
    "scripts/local-smoke.sh",
    "scripts/run-reviewed-bootstrap.sh",
}

# Each effectful command resolves to a detailed row in the existing catalogue.
# The prefix is checked for a unique match to avoid repeating long row titles.
DEFAULT_FAMILY = {
    "HostCommand": "Guarded NixOS activation",
    "ContextCommand": "Context profile replacement and removal",
    "InfraCommand": "Pulumi cloud stack preview/apply",
    "EnvCommand": "Application environment and Secret stores",
    "SecretCommand": "Application environment and Secret stores",
    "StorageCommand": "Application volume snapshot and restore",
    "DbCommand": "Standalone database creation and application deploy databases",
    "BrokerCommand": "Standalone Redpanda broker and logical topics",
    "TaskCommand": "Manual task run/delete and database/broker restart",
    "WorkerCommand": "Standalone worker Deployment and PVCs",
    "AccessCommand": "Protected Service access routes and shared auth settings",
    "PortalCommand": "Protected Service access routes and shared auth settings",
    "CdnCommand": "Cloudflare CDN host DNS",
}

FAMILY_ROUTES = {
    "InventoryPlan InventoryAdopt InventoryMigrate InventoryApply InventoryResume InventoryRecover InventoryClose InventoryRegistryRecoveryPlan": "Scoped review observation and operation selection",
    "InventoryRetire": "Partial scope member retirement",
    "InventoryCollect": "Retained stateless Kubernetes collection",
    "InventoryStoreMaterializeNative InventoryStoreMigrate InventoryExport InventoryRestore": "Inventory history export, restore, and store migration",
    "PlatformBootstrapPlan PlatformBootstrapApply": "Bootstrap release marker",
    "Deploy": "Standalone web Service with accepted databases and no CDN effects",
    "SiteDeploy SiteRollback SitePreviewDeploy SitePreviewDelete": "Static/server site deploy, rollback, and preview lifecycle",
    "AppRestart AppStop AppDelete AppDeploy": "Application Knative Service, databases, attached PVCs",
    "AppImagePlan": "Application OCI image publication",
    "Init": "Context image/state bucket and API bootstrap",
    "PlatformAdopt PlatformRepin": "Legacy platform release adoption and predeployment re-pin",
    "PlatformUpgrade PlatformUpgradeRollback PlatformUpgradeRecoverPulumi": "Coarse platform version upgrade",
    "Cleanup": "Image, stale-preview, and release-history cleanup",
    "ReleasePublish ReleaseCleanupStarter": "Global release payload publication",
    "HostCommand.HostPlaceAgeKey": "Host age-key placement",
    "HostCommand.HostImagePlan": "NixOS image object and GCE image publication",
    "HostCommand.HostStart HostCommand.HostStop": "VM start/stop",
    "KubeconfigCommand.KubeconfigRecover": "Context kubeconfig fetch and accepted-history recovery",
    "DbCommand.DbBackup DbCommand.DbPruneBackup DbCommand.DbBackupReceipts DbCommand.DbManualReceipt DbCommand.DbPruneScheduledBackups DbCommand.DbRecoverScheduledPrune DbCommand.DbDisableBackupPrune DbCommand.DbRestore": "Database backup and restore",
    "DbCommand.DbShell": "Interactive database maintenance",
    "DbCommand.DbRestart BrokerCommand.BrokerRestart": "Manual task run/delete and database/broker restart",
}


def family_assignments() -> dict[str, str]:
    result = {}
    for keys, prefix in FAMILY_ROUTES.items():
        for key in keys.split():
            result[key] = prefix
    return result

RECIPES = {
    "read": "default docs-validate terminology-validate reviews-validate user-documentation-validate nixos-registry-host nix-cache-status job-runs-status context-show status live-test test-inventory-effects haskell-style-check gate-fast gate gate-verify",
    "reviewed": "infra-up infra-preview infra-destroy cluster-bootstrap nix-cache-publish nix-cache-bootstrap job-runs-bootstrap cluster-enable-tls local-bootstrap local-minio observability deploy-hello host-switch host-image vm-start vm-stop smoke local-smoke",
    "bounded": "iap-ssh",
    "local": "local-up local-down nix-cache-secret-init install-hooks fixture-smoke",
    "pending": "",
}

RECIPE_FAMILY = {
    "cluster-bootstrap": "Bootstrap release marker",
    "nix-cache-publish": "Attic/Nix cache OCI image publication",
    "nix-cache-bootstrap": "Cache database, Attic workload",
    "job-runs-bootstrap": "Platform Namespaces and personal Job quota",
    "cluster-enable-tls": "Pinned cert-manager, issuer chain",
    "local-bootstrap": "Bootstrap release marker",
    "local-minio": "Local MinIO endpoint and backup bucket",
    "observability": "Helm releases and direct observability resources",
    "iap-ssh": "Guarded NixOS activation",
    "infra-up": "Pulumi cloud stack preview/apply",
    "infra-preview": "Pulumi cloud stack preview/apply",
    "infra-destroy": "Pulumi cloud stack preview/apply",
    "vm-stop": "VM start/stop",
    "vm-start": "VM start/stop",
    "host-image": "NixOS image object and GCE image publication",
    "host-switch": "Guarded NixOS activation",
    "deploy-hello": "Application Knative Service, databases, attached PVCs",
    "smoke": "Application volume snapshot and restore",
    "local-smoke": "Application volume snapshot and restore",
}

# Public library calls from production consumers are checked as an exact set.
# Pure observations are included so a new write cannot hide as an unlisted call.
LIBRARY_CALLS = {
    "cli/nagarectl/app": "applyInventoryWithFactory compileInventory convergeInventoryCandidateWith executionBlockedAdapterFor exportInventory loadCandidate loadTargetSnapshot loadTargetSnapshotReadOnly manifestAdapterFor migrateTargetStore openTargetStoreReadOnly openProfileReviewStoreReadOnly planInventory planInventoryAdoptionWith planInventoryCandidateAdoptionWith planInventoryCandidateWith planInventoryCandidateWithPayloadIdentity planInventoryCandidateWithRetirements planInventoryCollectionWith planInventoryCollectionsWith planInventoryMigrationCandidateWith planInventoryMigrationWith planInventoryRetirementWith planInventoryRetirementsWith planInventoryWithRetirements prepareRegistryRecoveryWithFactory recoverInventoryWithFactory closeInventoryWithFactory restoreInventory resumeInventoryWithFactoryTakeover selectFoundationStore",
    "cli/nagarectl/nagared/Main.hs": "loadTargetSnapshot openTargetStoreReadOnly",
}


def constructors(source: str, type_name: str) -> set[str]:
    match = re.search(
        rf"(?m)^data {re.escape(type_name)}\b(.*?)(?=^  deriving stock)",
        source,
        flags=re.M | re.S,
    )
    if match is None:
        raise ValueError(f"missing data {type_name} declaration")
    body = re.sub(r"--[^\n]*", "", match.group(1))
    return set(re.findall(r"[=|]\s*([A-Z][A-Za-z0-9_]*)\b", body))


def audit(source: str, dispatch_source: str, cli_root: Path) -> tuple[list[str], dict[str, dict[str, str]]]:
    errors: list[str] = []
    registered: dict[str, dict[str, str]] = {}
    for type_name, states in ROUTES.items():
        mapping: dict[str, str] = {}
        for state, names in states.items():
            for name in names.split():
                if name in mapping:
                    errors.append(f"{type_name}.{name} registered twice")
                mapping[name] = state
        actual = constructors(source, type_name)
        for name in sorted(actual - mapping.keys()):
            errors.append(f"unregistered constructor {type_name}.{name}")
        for name in sorted(mapping.keys() - actual):
            errors.append(f"stale registration {type_name}.{name}")
        registered[type_name] = mapping

    # Top-level constructors must be visibly dispatched. Nested constructors
    # are compiled through their run* functions and are tracked above.
    dispatch = dispatch_source.split("dispatch (mctx, cmd0) = case cmd0 of", 1)
    if len(dispatch) != 2:
        errors.append("cannot find the typed top-level command dispatcher")
    else:
        case_body = dispatch[1]
        for name in sorted(registered["Command"]):
            if not re.search(rf"(?m)^  {re.escape(name)}(?:\s|\()", case_body):
                errors.append(f"top-level command has no visible dispatch: {name}")

    for relative, markers in ENTRYPOINTS.items():
        path = ROOT / relative
        if not path.is_file():
            errors.append(f"registered entrypoint missing: {relative}")
            continue
        body = path.read_text()
        for marker in markers:
            if marker not in body:
                errors.append(f"registered entrypoint changed: {relative}: {marker}")
        if relative in {"scripts/local-smoke.sh", "scripts/live-smoke.sh"}:
            for pattern in SMOKE_BYPASS_PATTERNS:
                if re.search(pattern, body):
                    errors.append(f"smoke consumer has direct cleanup bypass: {relative}: {pattern}")

    recipe_source = (ROOT / "justfile").read_text()
    actual_recipes = set(re.findall(r"(?m)^([a-z][a-z0-9-]*)(?: [^\n:]*)?:", recipe_source))
    registered_recipes = [name for names in RECIPES.values() for name in names.split()]
    for name in sorted(actual_recipes - set(registered_recipes)):
        errors.append(f"unregistered recipe {name}")
    for name in sorted(set(registered_recipes) - actual_recipes):
        errors.append(f"stale recipe registration {name}")
    if len(registered_recipes) != len(set(registered_recipes)):
        errors.append("a recipe has more than one registration")
    actual_recipe_scripts = set(re.findall(r"scripts/[a-z0-9-]+\.sh", recipe_source))
    for path in sorted(actual_recipe_scripts - RECIPE_SCRIPTS):
        errors.append(f"unregistered recipe script {path}")
    for path in sorted(RECIPE_SCRIPTS - actual_recipe_scripts):
        errors.append(f"stale recipe script registration {path}")

    for relative, names in LIBRARY_CALLS.items():
        path = cli_root if relative == "cli/nagarectl/app" else ROOT / relative
        paths = sorted(path.rglob("*.hs")) if path.is_dir() else [path]
        body = "\n".join(
            line for path in paths for line in path.read_text().splitlines()
            if not line.startswith("import ")
        )
        actual = set(re.findall(r"\bInventory\.([a-z][A-Za-z0-9_]*)", body))
        expected = set(names.split())
        for name in sorted(actual - expected):
            errors.append(f"unregistered inventory library call {relative}: {name}")
        for name in sorted(expected - actual):
            errors.append(f"stale inventory library call {relative}: {name}")

    catalogue_rows = {}
    for line in CATALOGUE.read_text().splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if line.startswith("| ") and len(cells) == 8 and cells[0] != "Mutation family":
            catalogue_rows[cells[0]] = cells
    assignments = family_assignments()
    def validate_family(key: str, prefix: str | None) -> None:
        if prefix is None:
            errors.append(f"effectful route has no coverage family: {key}")
            return
        matches = [row for row in catalogue_rows if row.startswith(prefix)]
        if len(matches) != 1:
            errors.append(f"coverage family is not unique/present: {key}: {prefix}")
        elif any(not cell for cell in catalogue_rows[matches[0]][1:]):
            errors.append(f"coverage row lacks owner, compiler, executor, proof or disposition: {matches[0]}")

    for type_name, routes in registered.items():
        for name, state in routes.items():
            if state in {"read", "group", "local", "retired"}:
                continue
            key = f"{type_name}.{name}"
            prefix = assignments.get(key) or (
                assignments.get(name) if type_name == "Command" else None
            ) or DEFAULT_FAMILY.get(type_name)
            validate_family(key, prefix)
    for state, names in RECIPES.items():
        if state in {"read", "local"}:
            continue
        for name in names.split():
            validate_family(f"just {name}", RECIPE_FAMILY.get(name))
    return errors, registered


def catalogue_snapshot(registered: dict[str, dict[str, str]]) -> str:
    lines = [
        CATALOGUE_START,
        "| Entrypoint | Registered routes | Unresolved routes |",
        "| --- | ---: | --- |",
    ]
    for type_name, routes in registered.items():
        pending = sorted(name for name, state in routes.items() if state == "pending")
        lines.append(
            f"| `{type_name}` | {len(routes)} | "
            + (", ".join(f"`{name}`" for name in pending) if pending else "none")
            + " |"
        )
    lines.append(
        f"| `justfile` | {sum(len(names.split()) for names in RECIPES.values())} | "
        + ", ".join(f"`{name}`" for name in sorted(RECIPES["pending"].split()))
        + " |"
    )
    lines.append(
        f"| `Inventory.Command` production calls | "
        f"{sum(len(names.split()) for names in LIBRARY_CALLS.values())} | none |"
    )
    lines.append(CATALOGUE_END)
    return "\n".join(lines)


def catalogue_gaps(body: str) -> list[str]:
    gaps = []
    for line in body.splitlines():
        if not line.startswith("| ") or line.startswith("| Mutation family"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        # `excluded` rows are explicit guarded exclusions: their routes refuse
        # new admission and the catalogue names the guard.
        if len(cells) == 8 and cells[-1] in {
            "partial", "adapter-ready", "unavailable-after-admission"
        }:
            gaps.append(cells[0])
    return gaps


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli-source-dir", type=Path, default=CLI)
    parser.add_argument("--options-source", type=Path)
    parser.add_argument("--dispatch-source", type=Path)
    parser.add_argument("--coverage-result", type=Path)
    parser.add_argument("--update-catalogue", action="store_true")
    args = parser.parse_args()
    options = args.options_source or args.cli_source_dir / OPTIONS.relative_to(CLI)
    dispatch = args.dispatch_source or args.cli_source_dir / DISPATCH.relative_to(CLI)
    errors, registered = audit(options.read_text(), dispatch.read_text(), args.cli_source_dir)
    catalogue = CATALOGUE.read_text()
    snapshot = catalogue_snapshot(registered)
    if CATALOGUE_START in catalogue and CATALOGUE_END in catalogue:
        before, remainder = catalogue.split(CATALOGUE_START, 1)
        _, after = remainder.split(CATALOGUE_END, 1)
        updated_catalogue = before + snapshot + after
    else:
        updated_catalogue = catalogue.replace(
            "Each row names the lifecycle-owning scope,",
            snapshot + "\n\nEach row names the lifecycle-owning scope,",
            1,
        )
    if args.update_catalogue:
        CATALOGUE.write_text(updated_catalogue)
        catalogue = updated_catalogue
    elif updated_catalogue != catalogue:
        errors.append("managed command catalogue snapshot is stale")
    revision_check = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True,
        capture_output=True, check=False,
    )
    revision = revision_check.stdout.strip() if revision_check.returncode == 0 else "unavailable"
    status_check = subprocess.run(
        ["git", "status", "--porcelain"], cwd=ROOT, text=True,
        capture_output=True, check=False,
    )
    dirty = status_check.returncode != 0 or bool(status_check.stdout.strip())
    pending = sorted(
        f"{type_name}.{name}"
        for type_name, routes in registered.items()
        for name, state in routes.items()
        if state == "pending"
    )
    pending_recipes = sorted(RECIPES["pending"].split())
    deferred = DEFERRED_VARIANTS | {
        f"{type_name}.{name}"
        for type_name, routes in registered.items()
        for name, state in routes.items()
        if state == "deferred"
    }
    recovery_only = {
        f"{type_name}.{name}"
        for type_name, routes in registered.items()
        for name, state in routes.items()
        if state == "recovery"
    }
    if deferred != AUTHORIZED_DEFERRED:
        errors.append("deferred route set differs from the operator-approved boundary")
    if recovery_only != AUTHORIZED_RECOVERY_ONLY:
        errors.append("recovery-only route set differs from the retained recovery boundary")
    # Bind every executable module, not only the now-small process entry point.
    # Include paths so moving or omitting a consumer changes the identity too.
    source_members = {
        str(path.relative_to(args.cli_source_dir)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(args.cli_source_dir.rglob("*.hs"))
    }
    source_members[str(OPTIONS.relative_to(CLI))] = hashlib.sha256(options.read_bytes()).hexdigest()
    source_members[str(DISPATCH.relative_to(CLI))] = hashlib.sha256(dispatch.read_bytes()).hexdigest()
    result = {
        "schemaVersion": 1,
        "sourceRevision": revision,
        "candidateDigest": hashlib.sha256(json.dumps(source_members, sort_keys=True).encode()).hexdigest(),
        "dirty": dirty,
        "complete": not errors and not pending and not pending_recipes and not catalogue_gaps(catalogue) and not dirty,
        "registeredRoutes": sum(map(len, registered.values())),
        "entrypoints": sorted(ENTRYPOINTS),
        "recipes": sum(len(names.split()) for names in RECIPES.values()),
        "libraryCalls": sum(len(names.split()) for names in LIBRARY_CALLS.values()),
        "pending": pending,
        "pendingRecipes": pending_recipes,
        "deferredRoutes": sorted(deferred),
        "recoveryOnlyRoutes": sorted(recovery_only),
        "incompleteCatalogueRows": catalogue_gaps(catalogue),
        "errors": errors,
    }
    if args.coverage_result:
        args.coverage_result.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
