#!/usr/bin/env bash
# Exercise the public CLI before any provider process is available. A reviewed
# history head must close the remaining unscoped profile and cleanup writers.
set -euo pipefail

nagarectl_bin="${1:?pass the built nagarectl executable path}"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/nagare-inventory-entrypoints.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

export XDG_CONFIG_HOME="$fixture_root/config"
export XDG_STATE_HOME="$fixture_root/state"
context_dir="$XDG_CONFIG_HOME/nagare/contexts"
store_dir="$XDG_STATE_HOME/nagare/guarded/inventory"
mkdir -p "$context_dir" "$store_dir"
cat > "$context_dir/guarded.env" <<'EOF'
CLOUDSDK_CORE_PROJECT=project
NAGARE_MODE=local
EOF
python3 - "$store_dir/head.json" <<'PY'
import json
import sys

head = {
    "version": 1,
    "generation": 1,
    "sequence": 0,
    "binding": {"identity": "guarded", "project": "project"},
    "clientIdentity": "entrypoint-guard-test",
    "accepted": [],
    "converged": [],
    "activeTransaction": None,
    "executorClaim": None,
}
with open(sys.argv[1], "wb") as output:
    output.write(json.dumps(head, sort_keys=True, separators=(",", ":")).encode())
PY
chmod 600 "$store_dir/head.json"

refuse() {
  local label="$1"
  shift
  if "$nagarectl_bin" "$@" > "$fixture_root/out" 2>&1; then
    printf '%s unexpectedly succeeded\n' "$label" >&2
    exit 1
  fi
  if ! grep -q 'resource inventory history or transaction state' "$fixture_root/out"; then
    printf '%s refused for the wrong reason:\n' "$label" >&2
    cat "$fixture_root/out" >&2
    exit 1
  fi
}

refuse 'context delete' context delete guarded --yes
refuse 'context replacement' context create guarded --force --project other-project
refuse 'named init' init guarded --project other-project --skip-preflight
refuse 'legacy init' --context guarded init --project other-project --skip-preflight
refuse 'confirmed cleanup' --context guarded cleanup --confirm
test -f "$context_dir/guarded.env"
test -f "$store_dir/head.json"
python3 - "$store_dir/head.json" <<'PY'
import json
import sys

with open(sys.argv[1], "rb") as source:
    head = json.load(source)
head["generation"] = 0
with open(sys.argv[1], "wb") as output:
    output.write(json.dumps(head, sort_keys=True, separators=(",", ":")).encode())
PY
chmod 600 "$store_dir/head.json"
"$nagarectl_bin" context delete guarded --yes > "$fixture_root/out"
test ! -e "$context_dir/guarded.env"
test -f "$store_dir/head.json"
printf 'inventory entrypoint guards: five admitted refusals, untouched-store delete allowed\n'
