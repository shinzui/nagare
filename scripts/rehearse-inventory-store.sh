#!/usr/bin/env bash
# Rehearse a context's shared inventory from a fresh workstation state root.
# The real form migrates history to GCS and does not delete bucket objects.
set -euo pipefail

context=''
expected_project=''
dry_run=0
yes=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --context) context="${2:-}"; shift 2 ;;
    --expected-project) expected_project="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --yes) yes=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$context" ] && [ -n "$expected_project" ] || {
  echo 'provide --context and --expected-project' >&2; exit 2;
}
export NAGARE_CONTEXT="$context"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/target.sh
source "$script_dir/lib/target.sh"
[ "${NAGARE_MODE:-}" = cloud ] && [ "$TARGET_PROJECT" = "$expected_project" ] || {
  echo 'cloud context project does not match --expected-project' >&2; exit 1;
}

if [ "$dry_run" -eq 1 ]; then
  printf 'context=%s project=%s\n' "$context" "$expected_project"
  printf 'nagarectl inventory store migrate --to gcs --dry-run\n'
  printf 'with --yes: migrate, compare store status and exact export from two XDG state roots\n'
  printf 'the destination bucket prefix and its objects remain in place\n'
  exit 0
fi
[ "$yes" -eq 1 ] || { echo 'pass --yes after reviewing --dry-run' >&2; exit 2; }
_require_target_project
scratch="$(mktemp -d "${TMPDIR:-/tmp}/nagare-inventory-rehearsal.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
chmod 700 "$scratch"

nagarectl inventory store migrate --to gcs --yes
nagarectl inventory store status --json > "$scratch/first-status.json"
nagarectl inventory export --out "$scratch/first-export"

mkdir -m 700 "$scratch/second-state" "$scratch/second-cache"
XDG_STATE_HOME="$scratch/second-state" XDG_CACHE_HOME="$scratch/second-cache" \
  nagarectl inventory store status --json > "$scratch/second-status.json"
XDG_STATE_HOME="$scratch/second-state" XDG_CACHE_HOME="$scratch/second-cache" \
  nagarectl inventory export --out "$scratch/second-export"

python3 - "$scratch/first-status.json" "$scratch/second-status.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as first, open(sys.argv[2]) as second:
    a, b = json.load(first), json.load(second)
assert a['headDigest'] == b['headDigest'], 'inventory heads differ between state roots'
assert a['binding'] == b['binding'], 'inventory bindings differ between state roots'
print('matching head digest:', a['headDigest'])
PY
diff -qr "$scratch/first-export" "$scratch/second-export"
printf 'matching exact inventory exports from two state roots\n'
