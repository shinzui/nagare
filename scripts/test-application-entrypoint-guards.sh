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
cp "$context_dir/guarded.env" "$context_dir/fresh.env"
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
refuse 'aggregate app deploy without image' 'requires --image-resource' \
  app deploy --tag v1 --file test/fixtures/app/kizashi/Config.hs
refuse 'standalone Service deploy without image' 'requires --image-resource' \
  deploy --tag v1 --file missing-config.hs
refuse 'standalone worker deploy without image' 'requires --image-resource' \
  worker deploy --tag v1 --file ../nagare-dsl/test/fixtures/worker/nagare/Config.hs
refuse 'static site deploy without image' 'requires --image-resource' \
  site deploy --file ../nagare-dsl/test/fixtures/static-site/nagare/Config.hs
refuse 'static preview deploy without image' 'requires --image-resource' \
  site preview deploy --name feature-x \
  --file ../nagare-dsl/test/fixtures/static-site/nagare/Config.hs
refuse 'timestamped task run' 'direct task run is refused' \
  task run notes cleanup
refuse 'direct task deletion' 'direct task delete is refused' \
  task delete notes cleanup --yes
refuse 'database create without recovery' 'reviewed database create requires --recovery-backup' \
  db create postgres fixture
refuse 'broker create without recovery' 'reviewed broker create requires --recovery-backup' \
  broker create redpanda fixture
refuse 'unaccepted database restart' 'reviewed data restart requires one accepted StatefulSet scope' \
  db restart fixture
refuse 'unaccepted broker restart' 'reviewed data restart requires one accepted StatefulSet scope' \
  broker restart fixture
refuse 'database deletion without review' 'save-plan' \
  db delete fixture
refuse 'broker deletion without review' 'save-plan' \
  broker delete fixture
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
refuse 'direct environment set' 'direct env set is refused' \
  env set hello --config ../nagare-dsl/test/fixtures/nagare/Config.hs KEY value
refuse 'direct environment delete' 'direct env delete is refused' \
  env delete hello --config ../nagare-dsl/test/fixtures/nagare/Config.hs KEY
printf 'KEY=value\n' > "$fixture_root/vars.env"
refuse 'direct environment sync' 'direct env sync is refused' \
  env sync hello --config ../nagare-dsl/test/fixtures/nagare/Config.hs --file "$fixture_root/vars.env"
refuse 'direct Secret set' 'direct secret set is refused' \
  secret set hello --config ../nagare-dsl/test/fixtures/nagare/Config.hs KEY
refuse 'direct Secret delete' 'direct secret delete is refused' \
  secret delete hello --config ../nagare-dsl/test/fixtures/nagare/Config.hs KEY
refuse 'unaccepted app restart' 'reviewed service action requires one accepted Service scope' \
  app restart fixture
refuse 'unaccepted app stop' 'reviewed service action requires one accepted Service scope' \
  app stop fixture
refuse 'unreviewed app deletion' 'requires --save-plan' \
  app delete fixture
refuse 'unreviewed site rollback' 'requires --save-plan' \
  site rollback --file ../nagare-dsl/test/fixtures/static-site/nagare/Config.hs prior-release
refuse 'unreviewed preview deletion' 'requires --save-plan' \
  site preview delete --file ../nagare-dsl/test/fixtures/static-site/nagare/Config.hs feature-x
refuse 'direct CDN purge' 'direct cdn purge is refused' \
  cdn purge hello.example.com
refuse 'direct CDN disable' 'direct cdn disable is refused' \
  cdn disable hello.example.com
refuse 'direct access grant' 'direct access grant is refused' \
  access grant --host hello.example.com --user fixture
refuse 'direct access revoke' 'direct access revoke is refused' \
  access revoke --host hello.example.com --user fixture
refuse 'direct portal sync' 'direct access portal sync is refused' \
  access portal sync

if "$nagarectl_bin" --context fresh db restart fixture > "$fixture_root/out" 2>&1; then
  printf 'fresh database restart unexpectedly succeeded\n' >&2
  exit 1
fi
if ! grep -q 'inventory store is not initialized' "$fixture_root/out"; then
  printf 'fresh database restart refused for the wrong reason:\n' >&2
  cat "$fixture_root/out" >&2
  exit 1
fi
test ! -e "$XDG_STATE_HOME/nagare/fresh/inventory/head.json"

cmp -s "$store_dir/head.json" "$fixture_root/head-before"
printf 'application entrypoint guards: thirty-three live refusals and fresh restart refusal, inventory heads unchanged\n'
