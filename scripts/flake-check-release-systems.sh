#!/usr/bin/env bash
# The full gate's flake check: one `nix flake check` per release system, together.
# `--all-systems` would also evaluate tooling-only systems, whose
# import-from-derivation needs a native builder the landing gate does not have.
set -uo pipefail

pids=()
while IFS= read -r system; do
  nix flake check --system "$system" --keep-going --print-build-logs &
  pids+=("$!")
done < <(jq -r '.supportedSystems[]' release.json)

status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=1
done
exit "$status"
