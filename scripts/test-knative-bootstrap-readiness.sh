#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

sed -e "s|@BASH@|$(command -v bash)|g" > "$fake_bin/kubectl" <<'FAKE_KUBECTL'
#!@BASH@
set -euo pipefail

count=0
if [ -f "$FAKE_KUBECTL_COUNT" ]; then
  count="$(cat "$FAKE_KUBECTL_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_KUBECTL_COUNT"
printf '%s\n' "$*" >> "$FAKE_KUBECTL_LOG"
if [ "${1:-}" = create ]; then
  cat > "$FAKE_KUBECTL_LOG.manifest"
fi

if [ "${FAKE_KUBECTL_ALWAYS_FAIL:-0}" = 1 ] ||
   [ "$count" -le "${FAKE_KUBECTL_FAIL_UNTIL:-0}" ]; then
  printf '%s\n' "${FAKE_KUBECTL_ERROR:-}" >&2
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
  unset FAKE_KUBECTL_ALWAYS_FAIL FAKE_KUBECTL_FAIL_UNTIL FAKE_KUBECTL_ERROR
}

reset_fake
export FAKE_KUBECTL_FAIL_UNTIL=2
export FAKE_KUBECTL_ERROR='failed calling webhook "webhook.cert-manager.io": x509: certificate signed by unknown authority'
NAGARE_CERT_MANAGER_API_MAX_ATTEMPTS=3 NAGARE_CERT_MANAGER_API_RETRY_DELAY_SECONDS=0 \
  bash "$repo_root/scripts/wait-cert-manager-api.sh"
[ "$(cat "$FAKE_KUBECTL_COUNT")" -eq 3 ]
[ "$(grep -Fxc 'create --dry-run=server --request-timeout=10s -f -' "$FAKE_KUBECTL_LOG")" -eq 3 ]
grep -Fq 'kind: ClusterIssuer' "$FAKE_KUBECTL_LOG.manifest"
grep -Fq 'selfSigned: {}' "$FAKE_KUBECTL_LOG.manifest"

for error_kind in transient forbidden unrelated; do
  reset_fake
  export FAKE_KUBECTL_ALWAYS_FAIL=1
  case "$error_kind" in
    transient)
      export FAKE_KUBECTL_ERROR='failed calling webhook "webhook.cert-manager.io": no endpoints available for service'
      expected_attempts=3 ;;
    forbidden)
      export FAKE_KUBECTL_ERROR='Error from server (Forbidden): clusterissuers is forbidden'
      expected_attempts=1 ;;
    unrelated)
      export FAKE_KUBECTL_ERROR='failed calling webhook "other.example.com": x509: certificate signed by unknown authority'
      expected_attempts=1 ;;
  esac
  if NAGARE_CERT_MANAGER_API_MAX_ATTEMPTS=3 NAGARE_CERT_MANAGER_API_RETRY_DELAY_SECONDS=0 \
    bash "$repo_root/scripts/wait-cert-manager-api.sh" 2> "$test_root/api-error"; then
    echo "FAIL: cert-manager API gate accepted $error_kind error" >&2
    exit 1
  else
    [ "$?" -eq 23 ]
  fi
  [ "$(cat "$FAKE_KUBECTL_COUNT")" -eq "$expected_attempts" ]
  grep -Fq "$FAKE_KUBECTL_ERROR" "$test_root/api-error"
done
echo 'ok: cert-manager admission waits for trust and fails closed on unrelated errors'

cloud_dry_run="$test_root/cluster-bootstrap"
local_dry_run="$test_root/local-bootstrap"
just --justfile "$repo_root/justfile" --dry-run cluster-bootstrap > "$cloud_dry_run" 2>&1
just --justfile "$repo_root/justfile" --dry-run local-bootstrap > "$local_dry_run" 2>&1

for transcript in "$cloud_dry_run" "$local_dry_run"; do
  grep -Fxq 'scripts/run-reviewed-bootstrap.sh' "$transcript"
  if grep -Eq 'kubectl (apply|patch)|nagarectl platform stamp' "$transcript"; then
    echo 'FAIL: bootstrap bypasses reviewed inventory' >&2
    exit 1
  fi
done
grep -Fq 'nagarectl platform bootstrap plan --out "$review_dir"' "$repo_root/scripts/run-reviewed-bootstrap.sh"
grep -Fq 'nagarectl platform bootstrap apply "$review_dir" --yes' "$repo_root/scripts/run-reviewed-bootstrap.sh"

echo "ok: cloud and local bootstrap use reviewed inventory"
echo "knative bootstrap readiness tests: PASS"
