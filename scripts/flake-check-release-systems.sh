#!/usr/bin/env bash
# The full gate's flake check over release systems only. `--all-systems` would
# also evaluate tooling-only systems, whose import-from-derivation needs a
# native builder the landing gate does not have. `flake check --system` is used
# only to validate outputs: it treats this machine as that system, so builds go
# through one `nix build` that sends each check to a builder for its own system.
set -uo pipefail

status=0
installables=()
while IFS= read -r system; do
  nix flake check --no-build --system "$system" || status=1
  attrs="$(nix eval --json ".#checks.$system" --apply builtins.attrNames)" || exit 1
  while IFS= read -r attr; do
    installables+=(".#checks.$system.$attr")
  done < <(jq -r '.[]' <<<"$attrs")
done < <(jq -r '.supportedSystems[]' release.json)

[[ ${#installables[@]} -gt 0 ]] || exit 1
nix build --no-link --keep-going --print-build-logs "${installables[@]}" || status=1
exit "$status"
