#!/usr/bin/env bash
# EP-113: prove that `_require_bucket_in_target_project` in scripts/lib/target.sh
# fails closed. GCS bucket names are global, so a same-named bucket in a foreign
# project is reachable by name; the only reliable defence is comparing owning
# PROJECT NUMBERS, and an unreadable number must be a refusal rather than
# permission to continue.
#
# The test puts a recording fake `gcloud` first on PATH, points XDG_CONFIG_HOME /
# XDG_STATE_HOME at a temporary tree, writes a context file that declares a known
# project, then sources the resolver in a subshell and calls the function.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fake_bin="$test_root/bin"
ctx_dir="$test_root/config/nagare/contexts"
mkdir -p "$fake_bin" "$ctx_dir" "$test_root/state"

# Recording fake gcloud. Every invocation appends its argv to $GCLOUD_LOG. The
# two reads the guard performs answer from environment variables the case sets,
# so a case can simulate a foreign owner or an unreadable value (empty output).
printf '#!%s\n' "$(command -v bash)" > "$fake_bin/gcloud"
cat >> "$fake_bin/gcloud" <<'FAKE_GCLOUD'
set -euo pipefail
printf '%s\n' "$*" >> "${GCLOUD_LOG:?GCLOUD_LOG unset}"
case " $* " in
  *" storage buckets describe "*)
    printf '%s' "${FAKE_BUCKET_PROJECT_NUMBER:-}"
    [ -n "${FAKE_BUCKET_PROJECT_NUMBER:-}" ] || exit 1
    ;;
  *" projects describe "*)
    printf '%s' "${FAKE_TARGET_PROJECT_NUMBER:-}"
    [ -n "${FAKE_TARGET_PROJECT_NUMBER:-}" ] || exit 1
    ;;
  *" config get-value project "*)
    printf '%s' "${FAKE_CONFIGURED_PROJECT:-}"
    ;;
  *)
    exit 3
    ;;
esac
FAKE_GCLOUD
chmod +x "$fake_bin/gcloud"

cat > "$ctx_dir/guardtest.env" <<'CTX'
export CLOUDSDK_CORE_PROJECT=nagare-guard-test
export CLOUDSDK_COMPUTE_REGION=us-west1
export CLOUDSDK_COMPUTE_ZONE=us-west1-a
export NAGARE_MODE=cloud
CTX

cat > "$ctx_dir/guardlocal.env" <<'CTX'
export NAGARE_MODE=local
export NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io
export NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000
export NAGARE_LOCAL_OBJECT_STORE=http://127.0.0.1:9000
CTX

export PATH="$fake_bin:$PATH"
export XDG_CONFIG_HOME="$test_root/config"
export XDG_STATE_HOME="$test_root/state"

# Run the guard in a clean subshell: sourcing target.sh mutates the environment,
# and each case must start from the same slate.
run_guard() {
  local ctx="$1" log="$2" bucket_pn="$3" target_pn="$4"
  : > "$log"
  env -i \
    PATH="$PATH" \
    HOME="$test_root" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_STATE_HOME="$XDG_STATE_HOME" \
    NAGARE_CONTEXT="$ctx" \
    GCLOUD_LOG="$log" \
    FAKE_BUCKET_PROJECT_NUMBER="$bucket_pn" \
    FAKE_TARGET_PROJECT_NUMBER="$target_pn" \
    bash -c '
      set -euo pipefail
      source "'"$repo_root"'/scripts/lib/target.sh"
      _require_bucket_in_target_project nagare-guard-test-images "use a unique name."
    '
}

log="$test_root/gcloud.log"

# 1. Matching project numbers proceed.
run_guard guardtest "$log" 999999999999 999999999999 >/dev/null 2>&1
echo "ok: matching project numbers proceed"

# 2. A bucket owned by a different project number refuses.
if run_guard guardtest "$log" 111111111111 999999999999 > "$test_root/out2" 2> "$test_root/err2"; then
  echo "FAIL: a foreign bucket project number was accepted" >&2
  exit 1
fi
grep -q "refusing: gs://nagare-guard-test-images is owned by project number '111111111111'" "$test_root/err2"
grep -q "not the target project 'nagare-guard-test'" "$test_root/err2"
echo "ok: a foreign bucket project number refuses"

# 3. An unreadable bucket project number (missing tool, missing permission,
#    network failure) is a MISMATCH, not permission to continue.
if run_guard guardtest "$log" "" 999999999999 > "$test_root/out3" 2> "$test_root/err3"; then
  echo "FAIL: an unreadable bucket project number was accepted" >&2
  exit 1
fi
grep -q "project number '<unknown>'" "$test_root/err3"
echo "ok: an unreadable bucket project number refuses"

# 4. Local mode has no bucket and no project: succeed without invoking gcloud.
run_guard guardlocal "$log" 111111111111 999999999999 >/dev/null 2>&1
if [ -s "$log" ]; then
  echo "FAIL: local mode invoked gcloud:" >&2
  cat "$log" >&2
  exit 1
fi
echo "ok: local mode returns success without invoking gcloud"
