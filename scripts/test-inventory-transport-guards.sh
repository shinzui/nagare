#!/usr/bin/env bash
set -euo pipefail

work="$(mktemp -d -t nagare-inventory-transport.XXXXXX)"
trap 'rm -rf "$work"' EXIT

assert_refused() {
  local expected="$1"
  shift
  if NAGARE_INVENTORY_TRANSACTION=tx-test NAGARE_INVENTORY_ADAPTER_CHILD=wrong \
    "$@" >"$work/out" 2>"$work/err"; then
    echo "inventory transport unexpectedly accepted a foreign adapter child: $*" >&2
    exit 1
  fi
  grep -q "$expected" "$work/err"
}

assert_refused 'artifact adapter child marker' bash scripts/upload-images.sh --dry-run
assert_refused 'artifact adapter child marker' bash scripts/inventory-artifact-transport.sh observe
assert_refused 'host adapter child marker' bash scripts/host-switch.sh --dry-run
assert_refused 'host adapter child marker' bash scripts/inventory-host-transport.sh observe
assert_refused 'cache adapter child marker' bash scripts/inventory-cache-transport.sh observe
assert_refused 'artifact adapter child marker' bash scripts/setup-nix-builder.sh
assert_refused 'host adapter child marker' bash scripts/vm-power.sh start
assert_refused 'artifact adapter child marker' bash cluster/bootstrap/nix-cache/publish-image.sh
assert_refused 'artifact adapter child marker' bash cluster/bootstrap/net-certmanager/publish-image.sh

request="$(jq -nc --arg digest "$(printf 'a%.0s' {1..64})" \
  '{version:1,resource:"fixture",kind:"OciImageArtifact",destination:"127.0.0.1:5001/fixture:tag",expectedDigest:$digest,specDigest:$digest,plan:null}')"
if printf '%s' "$request" | NAGARE_INVENTORY_ADAPTER_CHILD=artifact \
  bash scripts/inventory-artifact-transport.sh publish >"$work/out" 2>"$work/err"; then
  echo "artifact transport accepted publication without a reviewed plan" >&2
  exit 1
fi
grep -q 'publication differs from the reviewed plan' "$work/err"

printf '%s\n' 'inventory transport re-entry guards passed'
