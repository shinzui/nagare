#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/kubectl" <<'FAKE_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail

count=0
if [ -f "$FAKE_KUBECTL_COUNT" ]; then
  count="$(cat "$FAKE_KUBECTL_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_KUBECTL_COUNT"
printf '%s\n' "$*" >> "$FAKE_KUBECTL_LOG"

if [ "${FAKE_KUBECTL_ALWAYS_FAIL:-0}" = 1 ] ||
   [ "$count" -le "${FAKE_KUBECTL_FAIL_UNTIL:-0}" ]; then
  exit "${FAKE_KUBECTL_FAILURE_STATUS:-23}"
fi
FAKE_KUBECTL
chmod +x "$fake_bin/kubectl"

export PATH="$fake_bin:$PATH"
export FAKE_KUBECTL_COUNT="$test_root/kubectl-count"
export FAKE_KUBECTL_LOG="$test_root/kubectl-log"
export FAKE_KUBECTL_FAILURE_STATUS=23

reset_fake() {
  rm -f -- "$FAKE_KUBECTL_COUNT" "$FAKE_KUBECTL_LOG"
  unset FAKE_KUBECTL_ALWAYS_FAIL FAKE_KUBECTL_FAIL_UNTIL
}

reset_fake
export FAKE_KUBECTL_FAIL_UNTIL=2
NAGARE_KNATIVE_PATCH_MAX_ATTEMPTS=5 \
NAGARE_KNATIVE_PATCH_RETRY_DELAY_SECONDS=0 \
  "$repo_root/scripts/retry-knative-configmap-patch.sh" \
    config-network --type merge --patch '{"data":{"ingress.class":"kourier"}}'
[ "$(cat "$FAKE_KUBECTL_COUNT")" -eq 3 ]
[ "$(wc -l < "$FAKE_KUBECTL_LOG")" -eq 3 ]
grep -Fxq -- \
  '-n knative-serving patch configmap config-network --type merge --patch {"data":{"ingress.class":"kourier"}}' \
  "$FAKE_KUBECTL_LOG"

reset_fake
export FAKE_KUBECTL_ALWAYS_FAIL=1
failure_stderr="$test_root/permanent-failure-stderr"
if NAGARE_KNATIVE_PATCH_MAX_ATTEMPTS=3 \
   NAGARE_KNATIVE_PATCH_RETRY_DELAY_SECONDS=0 \
     "$repo_root/scripts/retry-knative-configmap-patch.sh" \
       config-features --type merge --patch '{"data":{"kubernetes.podspec-persistent-volume-claim":"enabled"}}' \
       2> "$failure_stderr"; then
  echo "FAIL: permanently failing kubectl unexpectedly succeeded" >&2
  exit 1
else
  failure_status=$?
fi
[ "$failure_status" -eq 23 ]
[ "$(cat "$FAKE_KUBECTL_COUNT")" -eq 3 ]
grep -Fq 'config-features patch failed after 3 attempts' "$failure_stderr"
echo "ok: Knative ConfigMap patches retry and preserve the final failure"

cloud_dry_run="$test_root/cluster-bootstrap"
local_dry_run="$test_root/local-bootstrap"
just --justfile "$repo_root/justfile" --dry-run cluster-bootstrap > "$cloud_dry_run" 2>&1
just --justfile "$repo_root/justfile" --dry-run local-bootstrap > "$local_dry_run" 2>&1

line_of() {
  local transcript="$1"
  local needle="$2"
  awk -v needle="$needle" 'index($0, needle) { print NR; exit }' "$transcript"
}

assert_order() {
  local transcript="$1"
  shift
  local previous=0
  local needle line
  for needle in "$@"; do
    line="$(line_of "$transcript" "$needle")"
    if [ -z "$line" ] || [ "$line" -le "$previous" ]; then
      echo "FAIL: expected '$needle' after line $previous in $transcript" >&2
      exit 1
    fi
    previous="$line"
  done
}

assert_order "$cloud_dry_run" \
  '/serving-core.yaml' \
  'rollout status deploy/webhook --timeout=5m' \
  'retry-knative-configmap-patch.sh config-network'
assert_order "$cloud_dry_run" \
  '/net-certmanager.yaml' \
  'rollout status deploy/net-certmanager-webhook --timeout=5m' \
  'retry-knative-configmap-patch.sh config-certmanager' \
  'retry-knative-configmap-patch.sh config-deployment' \
  'nagarectl platform stamp'
assert_order "$local_dry_run" \
  '/serving-core.yaml' \
  'rollout status deploy/webhook --timeout=5m' \
  'retry-knative-configmap-patch.sh config-network' \
  'retry-knative-configmap-patch.sh config-deployment' \
  'nagarectl platform stamp'

[ "$(grep -Fc 'rollout status deploy/cert-manager-webhook --timeout=5m' "$cloud_dry_run")" -eq 1 ]
[ "$(grep -Fc 'rollout status deploy/cert-manager-webhook --timeout=5m' "$local_dry_run")" -eq 1 ]
[ "$(grep -Fc 'rollout status deploy/webhook --timeout=5m' "$cloud_dry_run")" -eq 1 ]
[ "$(grep -Fc 'rollout status deploy/webhook --timeout=5m' "$local_dry_run")" -eq 1 ]
[ "$(grep -Fc 'rollout status deploy/net-certmanager-webhook --timeout=5m' "$cloud_dry_run")" -eq 1 ]

echo "ok: cloud and local bootstrap wait before dependent patches"
echo "knative bootstrap readiness tests: PASS"
