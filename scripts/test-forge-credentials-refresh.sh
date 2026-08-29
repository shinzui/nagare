#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
refresh_script="$repo_root/nixos/hosts/nagare-01/forge-credentials-refresh.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fake_bin="$test_root/bin"
runtime_dir="$test_root/runtime"
mkdir -p "$fake_bin" "$runtime_dir"

printf '%s\n' 12345 > "$test_root/app-id"
printf '%s\n' 67890 > "$test_root/installation-id"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out "$test_root/private-key.pem" >/dev/null 2>&1

printf '#!%s\n' "$(command -v bash)" > "$fake_bin/curl"
cat >> "$fake_bin/curl" <<'FAKE_CURL'
set -euo pipefail
config_file=${2:?missing curl config}
output_file="$(awk -F'"' '$1 == "output = " { print $2 }' "$config_file")"
case "${FAKE_CURL_MODE:-success}" in
  success)
    printf '%s\n' '{"token":"test-installation-token","expires_at":"2026-08-25T23:59:59Z"}' > "$output_file"
    printf '%s' 201
    ;;
  malformed)
    printf '%s\n' '{"token":"replacement-must-not-publish"}' > "$output_file"
    printf '%s' 201
    ;;
  failure)
    printf '%s\n' '{"message":"not found"}' > "$output_file"
    printf '%s' 404
    exit 22
    ;;
  *)
    exit 2
    ;;
esac
FAKE_CURL

printf '#!%s\n' "$(command -v bash)" > "$fake_bin/k3s"
cat >> "$fake_bin/k3s" <<'FAKE_K3S'
set -euo pipefail
case " $* " in
  *" create secret generic nagare-forge-read "*)
    arguments=" $* "
    [[ "$arguments" == *" --from-file=token=$RUNTIME_DIRECTORY/token "* ]] || exit 3
    [[ "$arguments" == *" --from-file=GITHUB_TOKEN=$RUNTIME_DIRECTORY/GITHUB_TOKEN "* ]] || exit 3
    [[ "$arguments" == *" --from-file=expires_at=$RUNTIME_DIRECTORY/expires_at "* ]] || exit 3
    printf '%s\n' 'apiVersion: v1' 'kind: Secret' 'metadata:' '  name: nagare-forge-read'
    ;;
  *" apply -f - "*)
    tee "$TEST_APPLY_LOG" >/dev/null
    ;;
  *)
    exit 4
    ;;
esac
FAKE_K3S
chmod +x "$fake_bin/curl" "$fake_bin/k3s"

export PATH="$fake_bin:$PATH"
export RUNTIME_DIRECTORY="$runtime_dir"
export TEST_APPLY_LOG="$test_root/applied.yaml"

run_refresh() {
  bash "$refresh_script" \
    read \
    "$test_root/app-id" \
    "$test_root/installation-id" \
    "$test_root/private-key.pem" \
    nagare-forge-read \
    personal
}

export FAKE_CURL_MODE=success
run_refresh
cmp "$runtime_dir/token" "$runtime_dir/GITHUB_TOKEN"
grep -qx 'test-installation-token' "$runtime_dir/token"
grep -qx '2026-08-25T23:59:59Z' "$runtime_dir/expires_at"
grep -q 'name: nagare-forge-read' "$TEST_APPLY_LOG"

printf '%s\n' old-token > "$runtime_dir/token"
printf '%s\n' old-token > "$runtime_dir/GITHUB_TOKEN"
printf '%s\n' 2026-08-25T23:00:00Z > "$runtime_dir/expires_at"
rm -f -- "$TEST_APPLY_LOG"

export FAKE_CURL_MODE=malformed
if run_refresh >/dev/null 2>&1; then
  printf '%s\n' 'malformed GitHub response unexpectedly succeeded' >&2
  exit 1
fi
grep -qx old-token "$runtime_dir/token"
grep -qx 2026-08-25T23:00:00Z "$runtime_dir/expires_at"
test ! -e "$TEST_APPLY_LOG"

export FAKE_CURL_MODE=failure
if run_refresh >/dev/null 2>&1; then
  printf '%s\n' 'non-2xx GitHub response unexpectedly succeeded' >&2
  exit 1
fi
grep -qx old-token "$runtime_dir/token"
grep -qx 2026-08-25T23:00:00Z "$runtime_dir/expires_at"
test ! -e "$TEST_APPLY_LOG"

printf '%s\n' 'forge credential refresh tests passed'
