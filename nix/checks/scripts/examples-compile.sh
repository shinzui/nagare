#!/usr/bin/env bash
set -euo pipefail

cd "$src"
fail=0
for cfg in cluster/examples/*/nagare/Config.hs; do
  dir="$(dirname "$cfg")"
  echo "== compiling $cfg =="
  if ! runghc -XGHC2024 -i"$dir" "$cfg" >/dev/null; then
    echo "FAILED: $cfg" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1
touch "$out"
