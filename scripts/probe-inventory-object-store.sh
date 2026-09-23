#!/usr/bin/env bash
# Probe conditional object writes under a unique child of an explicit GCS URL.
# Cloud objects are deliberately retained as evidence.
set -euo pipefail

dry_run=0
url=''
expected_project=''
context=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --url) url="${2:-}"; shift 2 ;;
    --expected-project) expected_project="${2:-}"; shift 2 ;;
    --context) context="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$context" ] && export NAGARE_CONTEXT="$context"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/target.sh
source "$script_dir/lib/target.sh"

if [ "${NAGARE_MODE:-}" != cloud ]; then
  echo 'inventory object-store probe requires a cloud context' >&2
  exit 1
fi
if [ -z "$url" ] || [ -z "$expected_project" ] || [ "$expected_project" != "$TARGET_PROJECT" ]; then
  echo 'provide --url gs://bucket/prefix and the exact active --expected-project' >&2
  exit 2
fi
case "$url" in
  gs://*/*) ;;
  *) echo 'probe URL must include a GCS bucket and private prefix' >&2; exit 2 ;;
esac
bucket="${url#gs://}"
bucket="${bucket%%/*}"
case "$bucket" in
  ''|*[!a-zA-Z0-9._-]*) echo 'invalid probe bucket' >&2; exit 2 ;;
esac
prefix="${url%/}/probe-$(date -u +%Y%m%dT%H%M%SZ)-$$"
object="$prefix/conditional.txt"
if [ "$dry_run" -eq 1 ]; then
  printf 'context=%s project=%s bucket=gs://%s\n' "${NAGARE_CONTEXT:-default}" "$TARGET_PROJECT" "$bucket"
  printf 'create-if-absent: gcloud storage cp <private-file> %s --if-generation-match=0\n' "$object"
  printf 'repeat create-if-absent; replace by observed generation; retry stale generation; list and read back\n'
  printf 'probe objects remain under %s\n' "$prefix"
  exit 0
fi

_require_target_project
_require_bucket_in_target_project "$bucket"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/nagare-inventory-probe.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
printf 'first\n' > "$scratch/object"
chmod 600 "$scratch/object"

now() { python3 -c 'import time; print(time.monotonic())'; }
report() {
  local label="$1" code="$2" start="$3" message="$4"
  local elapsed
  elapsed="$(python3 -c 'import sys,time; print(f"{time.monotonic()-float(sys.argv[1]):.3f}s")' "$start")"
  printf '%s exit=%s elapsed=%s %s\n' "$label" "$code" "$elapsed" "$message"
}
run_cp() {
  local label="$1" generation="$2" start code first_line
  start="$(now)"
  if gcloud storage cp "$scratch/object" "$object" "--if-generation-match=$generation" --quiet \
    > "$scratch/stdout" 2> "$scratch/stderr"; then code=0; else code=$?; fi
  first_line="$(sed -n '1p' "$scratch/stderr")"
  report "$label" "$code" "$start" "$first_line"
  return "$code"
}

run_cp create-if-absent 0
first_generation="$(gcloud storage objects describe "$object" --format='value(generation)')"
if run_cp duplicate-create 0; then
  echo 'create-if-absent unexpectedly overwrote an existing object' >&2
  exit 1
fi
printf 'second\n' > "$scratch/object"
run_cp replace "$first_generation"
if run_cp stale-replace "$first_generation"; then
  echo 'stale generation unexpectedly overwrote an object' >&2
  exit 1
fi
current="$(gcloud storage cat "$object")"
[ "$current" = second ] || { echo 'read-back content changed unexpectedly' >&2; exit 1; }
gcloud storage objects list "${prefix}/**" --format='value(name)'
printf 'read-back=second retained-prefix=%s\n' "$prefix"
