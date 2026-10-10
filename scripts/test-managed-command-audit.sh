#!/usr/bin/env bash
# A new typed mutation must be registered before the release audit accepts it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$repo_root/scripts/check-cli-architecture.py"
python3 "$repo_root/scripts/test-cli-architecture.py"
python3 "$repo_root/scripts/check-haskell-architecture.py"
python3 "$repo_root/scripts/test-haskell-architecture.py"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/nagare-command-audit.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

python3 "$repo_root/scripts/audit-managed-commands.py" > "$fixture_root/current.json"
python3 - "$repo_root/cli/nagarectl/app/Nagare/Cli/Options.hs" "$fixture_root/injected.hs" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = "  | Cleanup CleanupOpts\n"
assert source.count(needle) == 1
pathlib.Path(sys.argv[2]).write_text(
    source.replace(needle, needle + "  | AuditInjectedMutation\n", 1)
)
PY

if python3 "$repo_root/scripts/audit-managed-commands.py" \
    --options-source "$fixture_root/injected.hs" > "$fixture_root/injected.json"; then
  echo 'unregistered mutation unexpectedly passed the command audit' >&2
  exit 1
fi
python3 - "$fixture_root/current.json" "$fixture_root/injected.json" <<'PY'
import json
import pathlib
import sys

current, injected = [json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:]]
assert current['errors'] == [], current['errors']
assert current['deferredRoutes'] == [
    'DbCommand.DbRestore.--into-live',
    'DbCommand.DbShell',
    'StorageCommand.StorageRestore.--into-live',
]
assert current['recoveryOnlyRoutes'] == ['DbCommand.DbRecoverScheduledPrune', 'StorageCommand.StorageRecoverScheduledPrune']
assert 'unregistered constructor Command.AuditInjectedMutation' in injected['errors']
print(f"managed command audit: {current['registeredRoutes']} routes, "
      f"{current['recipes']} recipes, {current['libraryCalls']} library calls; "
      "injected mutation refused")
PY
# Both release assemblers pin these lists. They must follow the live audit, or every release
# assembly refuses with "mutation coverage is incomplete" (v0.5.0 candidate 42c0f0b3).
PYTHONDONTWRITEBYTECODE=1 python3 - "$repo_root" "$fixture_root/current.json" <<'PY'
import importlib.util
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
current = json.loads(pathlib.Path(sys.argv[2]).read_text())
spec = importlib.util.spec_from_file_location(
    "release_index", root / "scripts/assemble-inventory-release-index.py")
index = importlib.util.module_from_spec(spec)
spec.loader.exec_module(index)
assert index.DEFERRED_ROUTES == current['deferredRoutes'], index.DEFERRED_ROUTES
assert index.RECOVERY_ONLY_ROUTES == current['recoveryOnlyRoutes'], index.RECOVERY_ONLY_ROUTES
shell = (root / "scripts/assemble-managed-resource-evidence.sh").read_text()
for field in ('deferredRoutes', 'recoveryOnlyRoutes'):
    match = re.search(r'\.' + field + r' == (\[[^\]]*\])', shell)
    assert match, field
    assert json.loads(match.group(1)) == current[field], (field, match.group(1))
# The CLI's release-evidence check (the publisher's) pins the same two lists.
cli = (root / "cli/nagarectl/src/Nagare/Inventory/ReleaseEvidence.hs").read_text()
for name, field in (('deferred', 'deferredRoutes'), ('recovery', 'recoveryOnlyRoutes')):
    match = re.search(r'\b' + name + r' == (\[[^\]]*\])', cli)
    assert match, name
    assert json.loads(match.group(1)) == current[field], (name, match.group(1))
print("managed command audit: both assemblers and the CLI pin the live deferred and recovery-only routes")
PY

python3 - "$repo_root" "$fixture_root" <<'PY'
import json
from pathlib import Path
import shutil
import subprocess
import sys

repo, fixture = map(Path, sys.argv[1:])
cli = fixture / "app"
shutil.copytree(repo / "cli/nagarectl/app", cli)
# A Nix sandbox copies sources read-only; the fixture must be editable.
for path in [cli, *cli.rglob("*")]:
    path.chmod(path.stat().st_mode | 0o200)
audit = [sys.executable, str(repo / "scripts/audit-managed-commands.py"),
         "--cli-source-dir", str(cli)]
before = json.loads(subprocess.check_output(audit, text=True))
consumer = cli / "Nagare/Cli/Runtime/Error.hs"
consumer.write_text(consumer.read_text() + "\nauditInjected = Inventory.unregisteredMutation\n")
result = subprocess.run(audit, text=True, capture_output=True)
after = json.loads(result.stdout)
assert result.returncode == 1
assert any("unregistered inventory library call" in error for error in after["errors"])
assert before["candidateDigest"] != after["candidateDigest"]
dispatch = cli / "Nagare/Cli/Dispatch.hs"
dispatch.write_text(dispatch.read_text().replace("  InventoryApply directory yes ->", "  MissingApply directory yes ->"))
result = subprocess.run(audit, text=True, capture_output=True)
assert "top-level command has no visible dispatch: InventoryApply" in json.loads(result.stdout)["errors"]
print("modular command audit: unregistered consumer and missing dispatch refused; all modules digest-bound")
PY
