#!/usr/bin/env bash
# IR-13: every nagare.host option the rendered operator module sets must be
# declared by the NixOS module. HostSpec pins the golden file to renderHostModule.
set -euo pipefail

golden="$src/cli/nagarectl/test/fixtures/host/host.nix"
module="$src/nixos/modules/nagare-host.nix"

declared="$(sed -n 's/^    \([A-Za-z][A-Za-z0-9]*\) = lib\.mkOption.*/\1/p; s/^    \([A-Za-z][A-Za-z0-9]*\) = {$/\1/p' "$module" | sort -u)"
rendered="$(sed -n 's/^    \([A-Za-z][A-Za-z0-9]*\) = .*/\1/p' "$golden" | sort -u)"
test -n "$declared"
test -n "$rendered"

unknown="$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$rendered"))"
if [ -n "$unknown" ]; then
  echo "rendered host.nix sets nagare.host options the NixOS module does not declare:" >&2
  printf '  %s\n' $unknown >&2
  exit 1
fi
touch "$out"
