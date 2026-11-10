#!/usr/bin/env bash
# The full gate's flake check over release systems only. `--all-systems` would
# also evaluate tooling-only systems, whose import-from-derivation needs a
# native builder the landing gate does not have. `flake check --system` cannot
# stand in: it treats this machine as that system, and with --no-build it cannot
# create import-from-derivation inputs. So evaluate each system's outputs, then
# send every check to a builder for its own system through one `nix build`.
set -uo pipefail

status=0
installables=()
while IFS= read -r system; do
  for output in packages devShells; do
    nix eval --json ".#$output.$system" --apply 'builtins.mapAttrs (_: v: v.drvPath)' >/dev/null || status=1
  done
  nix eval --json ".#apps.$system" --apply 'builtins.mapAttrs (_: v: v.program)' >/dev/null || status=1
  attrs="$(nix eval --json ".#checks.$system" --apply builtins.attrNames)" || exit 1
  while IFS= read -r attr; do
    installables+=(".#checks.$system.$attr")
  done < <(jq -r '.[]' <<<"$attrs")
done < <(jq -r '.supportedSystems[]' release.json)

[[ ${#installables[@]} -gt 0 ]] || exit 1
nix build --no-link --keep-going --print-build-logs "${installables[@]}" || status=1
exit "$status"
