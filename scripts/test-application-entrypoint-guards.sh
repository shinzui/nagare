#!/usr/bin/env bash
# An initialized inventory context must refuse live legacy application writes
# before any Kubernetes, registry, or task provider operation is attempted.
set -euo pipefail

nagarectl_bin="${1:?pass the built nagarectl executable path}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/nagare-application-entrypoints.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

export XDG_CONFIG_HOME="$fixture_root/config"
export XDG_STATE_HOME="$fixture_root/state"
unset CLOUDSDK_CORE_PROJECT
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
    "clientIdentity": "application-entrypoint-guard-test",
    "accepted": [],
    "converged": [],
    "activeTransaction": None,
    "executorClaim": None,
}
with open(sys.argv[1], "wb") as output:
    output.write(json.dumps(head, sort_keys=True, separators=(",", ":")).encode())
PY
chmod 600 "$store_dir/head.json"
cp "$store_dir/head.json" "$fixture_root/head-before"

refuse() {
  local label="$1"
  local expected="$2"
  shift 2
  if "$nagarectl_bin" --context guarded "$@" > "$fixture_root/out" 2>&1; then
    printf '%s unexpectedly succeeded\n' "$label" >&2
    exit 1
  fi
  if ! grep -q "$expected" "$fixture_root/out"; then
    printf '%s refused for the wrong reason:\n' "$label" >&2
    cat "$fixture_root/out" >&2
    exit 1
  fi
}

cd "$repo_root/cli/nagarectl"
refuse 'aggregate app deploy' 'inventory history is initialized' \
  app deploy --file test/fixtures/app/kizashi/Config.hs
refuse 'standalone Service deploy' 'inventory history is initialized' \
  deploy --file missing-config.hs
refuse 'standalone worker deploy' 'inventory history is initialized' \
  worker deploy --file ../nagare-dsl/test/fixtures/worker/nagare/Config.hs
refuse 'static site deploy' 'inventory history is initialized' \
  site deploy --file ../nagare-dsl/test/fixtures/static-site/nagare/Config.hs
refuse 'static preview deploy' 'inventory history is initialized' \
  site preview deploy --name feature-x \
  --file ../nagare-dsl/test/fixtures/static-site/nagare/Config.hs
refuse 'timestamped task run' 'direct task run is refused' \
  task run notes cleanup
refuse 'direct task deletion' 'direct task delete is refused' \
  task delete notes cleanup --yes
refuse 'direct database create' 'direct database create is refused' \
  db create postgres fixture
refuse 'direct broker create' 'direct broker create is refused' \
  broker create redpanda fixture
refuse 'direct database restart' 'direct data restart is refused' \
  db restart fixture
refuse 'direct broker restart' 'direct data restart is refused' \
  broker restart fixture
refuse 'direct database deletion' 'direct database delete is refused' \
  db delete fixture --yes
refuse 'direct broker deletion' 'direct broker delete is refused' \
  broker delete fixture --yes
refuse 'direct database backup' 'direct database backup is refused' \
  db backup fixture
refuse 'direct database restore' 'direct database restore is refused' \
  db restore fixture backup-identity
refuse 'direct database shell' 'direct database shell is refused' \
  db shell fixture
refuse 'direct volume snapshot' 'direct storage snapshot is refused' \
  storage snapshot hello --config ../nagare-dsl/test/fixtures/nagare/Config.hs data
refuse 'direct volume restore' 'direct storage restore is refused' \
  storage restore hello --config ../nagare-dsl/test/fixtures/nagare/Config.hs data backup-identity

cmp -s "$store_dir/head.json" "$fixture_root/head-before"
printf 'application entrypoint guards: eighteen live refusals, inventory head unchanged\n'
