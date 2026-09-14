#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

payload="$test_root/payload"
fake_bin="$test_root/bin"
log="$test_root/calls.log"
mkdir -p "$payload/cluster/bootstrap/net-certmanager" "$payload/scripts" "$fake_bin"
printf '%s\n' 'nagare/net-certmanager-controller:v1.14.0-nagare.1' \
  > "$payload/cluster/bootstrap/net-certmanager/image-reference"
printf '%s\n' 'fixture image archive' \
  > "$payload/cluster/bootstrap/net-certmanager/nagare-net-certmanager-controller.tar.gz"

for tool in k3d kubectl; do
  sed -e "s/@TOOL@/$tool/g" -e "s|@BASH@|$(command -v bash)|g" > "$fake_bin/$tool" <<'EOF'
#!@BASH@
set -euo pipefail
printf '%s %s\n' '@TOOL@' "$*" >> "${NAGARE_TEST_LOG:?}"
if [ '@TOOL@' = kubectl ] && [ "${1:-}" = -n ] && [ "${3:-}" = get ]; then
  printf '%s' 'nagare/net-certmanager-controller:v1.14.0-nagare.1'
fi
EOF
  chmod +x "$fake_bin/$tool"
done

sed -e "s|@BASH@|$(command -v bash)|g" > "$payload/scripts/iap-ssh.sh" <<'EOF'
#!@BASH@
set -euo pipefail
printf '%s %s\n' 'iap-ssh' "$*" >> "${NAGARE_TEST_LOG:?}"
EOF
chmod +x "$payload/scripts/iap-ssh.sh"

export NAGARE_PLATFORM_ROOT="$payload"
export NAGARE_TEST_LOG="$log"
export PATH="$fake_bin:$PATH"

bash "$repo_root/scripts/install-net-certmanager-controller.sh" --k3d-cluster nagare-test
grep -Fqx "k3d image import $payload/cluster/bootstrap/net-certmanager/nagare-net-certmanager-controller.tar.gz --cluster nagare-test" "$log"
grep -Fqx 'kubectl -n knative-serving set image deployment/net-certmanager-controller controller=nagare/net-certmanager-controller:v1.14.0-nagare.1' "$log"
grep -Fqx 'kubectl -n knative-serving rollout status deployment/net-certmanager-controller --timeout=5m' "$log"

: > "$log"
bash "$repo_root/scripts/install-net-certmanager-controller.sh" --cloud-instance nagare-01
grep -Eq "^iap-ssh scp $payload/cluster/bootstrap/net-certmanager/nagare-net-certmanager-controller.tar.gz nagare-01:/tmp/nagare-net-certmanager-controller-[0-9]+.tar.gz$" "$log"
grep -Eq '^iap-ssh ssh nagare-01 -- set -eu; trap .*sudo k3s ctr images import .* >/dev/null$' "$log"
grep -Fqx 'kubectl -n knative-serving set image deployment/net-certmanager-controller controller=nagare/net-certmanager-controller:v1.14.0-nagare.1' "$log"

if bash "$repo_root/scripts/install-net-certmanager-controller.sh" --k3d-cluster '../../foreign' > /dev/null 2>&1; then
  echo 'unsafe k3d cluster name unexpectedly accepted' >&2
  exit 1
fi

echo 'ok: patched controller archive is imported before the deployment rolls out'
