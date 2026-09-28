#!/usr/bin/env bash
# A new typed mutation must be registered before the release audit accepts it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/nagare-command-audit.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

python3 "$repo_root/scripts/audit-managed-commands.py" > "$fixture_root/current.json"
python3 - "$repo_root/cli/nagarectl/app/Main.hs" "$fixture_root/injected.hs" <<'PY'
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
    --main-source "$fixture_root/injected.hs" > "$fixture_root/injected.json"; then
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
    'DbCommand.DbPruneScheduledBackups',
    'DbCommand.DbRestore.--into-live',
    'DbCommand.DbShell',
    'StorageCommand.StorageRestore.--into-live',
]
assert current['recoveryOnlyRoutes'] == ['DbCommand.DbRecoverScheduledPrune']
assert 'unregistered constructor Command.AuditInjectedMutation' in injected['errors']
print(f"managed command audit: {current['registeredRoutes']} routes, "
      f"{current['recipes']} recipes, {current['libraryCalls']} library calls; "
      "injected mutation refused")
PY
