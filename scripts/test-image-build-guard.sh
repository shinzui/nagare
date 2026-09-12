#!/usr/bin/env bash
# EP-113: prove that the auth-plane image builders take their GCP project ONLY
# from the active target context, and refuse before any cloud mutation.
#
# Before this change, cluster/bootstrap/auth-images/build-local-image.sh resolved
# the project from `gcloud config get-value project` and never sourced the
# guardrail, so an operator whose gcloud still pointed at a production project
# submitted Cloud Build jobs there.
#
# The test runs the real script bytes, but against a MINIMAL platform root: the
# script stages its build context by rsyncing the whole platform tree, which for
# a real checkout is gigabytes. The fake root holds only the four files the
# script and the resolver actually read, so the staging is instant and the test
# reaches the cloud call. Fakes for `gcloud`, `docker` and `git` record every
# invocation.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fake_bin="$test_root/bin"
fake_root="$test_root/platform"
ctx_dir="$test_root/config/nagare/contexts"
src_dir="$test_root/src"
mkdir -p \
  "$fake_bin" \
  "$ctx_dir" \
  "$test_root/state" \
  "$test_root/tmp" \
  "$fake_root/scripts/lib" \
  "$fake_root/cluster/bootstrap/auth-images" \
  "$src_dir/shomei/deploy" \
  "$src_dir/en"

# The minimal platform root. release.json and justfile are what
# scripts/lib/target.sh validates its operational root with.
cp "$repo_root/release.json" "$fake_root/release.json"
cp "$repo_root/justfile" "$fake_root/justfile"
cp "$repo_root/scripts/lib/release.sh" "$fake_root/scripts/lib/release.sh"
cp "$repo_root/scripts/lib/target.sh" "$fake_root/scripts/lib/target.sh"
cp "$repo_root/cluster/bootstrap/auth-images/build-local-image.sh" \
  "$fake_root/cluster/bootstrap/auth-images/build-local-image.sh"
cp "$repo_root/cluster/bootstrap/auth-images/Dockerfile.local-haskell" \
  "$fake_root/cluster/bootstrap/auth-images/Dockerfile.local-haskell"
build_script="$fake_root/cluster/bootstrap/auth-images/build-local-image.sh"
printf '#!/bin/sh\nexec shomei-server "$@"\n' > "$src_dir/shomei/deploy/entrypoint.sh"

# Recording fake gcloud. It records every invocation and WOULD answer
# `config get-value project` with a production project, so any surviving
# fallback shows up in the log.
printf '#!%s\n' "$(command -v bash)" > "$fake_bin/gcloud"
cat >> "$fake_bin/gcloud" <<'FAKE_GCLOUD'
set -euo pipefail
printf '%s\n' "$*" >> "${GCLOUD_LOG:?GCLOUD_LOG unset}"
case " $* " in
  *" config get-value project "*) printf '%s\n' 'some-production-project' ;;
  *) : ;;
esac
FAKE_GCLOUD

# Recording fake docker: succeeds, so the script reaches its later steps.
printf '#!%s\n' "$(command -v bash)" > "$fake_bin/docker"
cat >> "$fake_bin/docker" <<'FAKE_DOCKER'
set -euo pipefail
printf '%s\n' "$*" >> "${DOCKER_LOG:?DOCKER_LOG unset}"
FAKE_DOCKER
chmod +x "$fake_bin/gcloud" "$fake_bin/docker"

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

gcloud_log="$test_root/gcloud.log"
docker_log="$test_root/docker.log"

# Run the build script in a clean environment. Extra `VAR=value` arguments after
# the context name are passed through to `env`.
run_build() {
  local ctx="$1"
  shift
  : > "$gcloud_log"
  : > "$docker_log"
  env -i \
    PATH="$fake_bin:$PATH" \
    HOME="$test_root" \
    TMPDIR="$test_root/tmp" \
    XDG_CONFIG_HOME="$test_root/config" \
    XDG_STATE_HOME="$test_root/state" \
    NAGARE_CONTEXT="$ctx" \
    GCLOUD_LOG="$gcloud_log" \
    DOCKER_LOG="$docker_log" \
    SHOMEI_SRC="$src_dir/shomei" \
    EN_SRC="$src_dir/en" \
    NAGARE_AUTH_TAG=test-tag \
    "$@" \
    bash "$build_script" shomei
}

# 1. An ambient CLOUDSDK_CORE_PROJECT that disagrees with the context must stop
#    the run before `gcloud builds submit`.
if run_build guardtest \
  CLOUDSDK_CORE_PROJECT=some-production-project \
  NAGARE_AUTH_BUILDER=cloud-build \
  NAGARE_AUTH_PUSH=1 \
  > "$test_root/out1" 2> "$test_root/err1"; then
  echo "FAIL: cloud-build proceeded with a disagreeing ambient project" >&2
  cat "$test_root/err1" >&2
  exit 1
fi
grep -q 'refusing to run:' "$test_root/err1"
if grep -q 'builds submit' "$gcloud_log"; then
  echo "FAIL: a Cloud Build job was submitted despite the refusal:" >&2
  cat "$gcloud_log" >&2
  exit 1
fi
echo "ok: cloud-build refuses when the ambient project disagrees with the context"

# 2. With no ambient CLOUDSDK_CORE_PROJECT and a fake gcloud whose
#    `config get-value project` would print a production project, the script must
#    not consult it. The context declares a project, so the guardrail's own
#    cross-check (which legitimately reads gcloud's configured project when
#    NOTHING declares one) does not run either: any `config get-value project` in
#    the log could then only have come from the deleted fallback.
run_build guardtest \
  NAGARE_AUTH_BUILDER=cloud-build \
  NAGARE_AUTH_PUSH=1 \
  > "$test_root/out2" 2> "$test_root/err2"
if grep -q 'config get-value project' "$gcloud_log"; then
  echo "FAIL: the ambient gcloud project fallback is still reachable:" >&2
  cat "$gcloud_log" >&2
  exit 1
fi
grep -q 'builds submit' "$gcloud_log"
grep -q -- '--project nagare-guard-test' "$gcloud_log"
if grep -q 'some-production-project' "$gcloud_log"; then
  echo "FAIL: a production project reached a gcloud invocation:" >&2
  cat "$gcloud_log" >&2
  exit 1
fi
echo "ok: the gcloud config fallback is gone (no 'config get-value project' call)"

# 3. A local-mode, no-push build must never invoke gcloud at all.
run_build guardlocal \
  NAGARE_AUTH_BUILDER=docker \
  NAGARE_AUTH_PUSH=0 \
  > "$test_root/out3" 2> "$test_root/err3"
if [ -s "$gcloud_log" ]; then
  echo "FAIL: a local-mode build invoked gcloud:" >&2
  cat "$gcloud_log" >&2
  exit 1
fi
grep -q '^build ' "$docker_log"
echo "ok: a local-mode no-push build never invokes gcloud"
