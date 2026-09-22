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

printf '%s\n' 'inventory transport re-entry guards passed'
