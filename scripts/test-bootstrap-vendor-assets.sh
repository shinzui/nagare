#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
lock="cluster/bootstrap/vendor/SHA256SUMS"
[ "$(find cluster/bootstrap/vendor -maxdepth 1 -name '*.yaml' -type f | wc -l | tr -d ' ')" = 5 ]
[ "$(wc -l < "$lock" | tr -d ' ')" = 5 ]
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c "$lock"
else
  shasum -a 256 -c "$lock"
fi
