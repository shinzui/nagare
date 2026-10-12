#!/usr/bin/env bash
# Build this system's release attachments from a clean checkout of the candidate:
# the release gate's attachments, the native output identities and the
# clone-free rehearsal. Run it once on each system in release.json, then
# assemble the outputs with scripts/assemble-release.sh (docs/runbooks/releases.md).
set -euo pipefail

usage() { echo "usage: $0 VERSION OUTPUT_DIR" >&2; exit 2; }
[[ $# -eq 2 ]] || usage
version="$1"
out="$2"

rev="$(git rev-parse HEAD)"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] \
  || { echo "release-native: the candidate checkout has uncommitted changes" >&2; exit 2; }
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
mkdir -p "$out"

./scripts/check-release.sh --version "$version" --output-dir "$out" --json > "$out/gate.json"
revision="$(jq -er '.revision' "$out/nagare-release-$version.json")"

cli_path="$(nix build --no-link --print-out-paths .#nagarectl)"
payload_path="$(nix build --no-link --print-out-paths .#nagare-platform)"
cli_info="$(nix path-info --json --json-format 1 "$cli_path" | jq --arg path "$cli_path" '.[$path] | {narHash, narSize}')"
payload_info="$(nix path-info --json --json-format 1 "$payload_path" | jq --arg path "$payload_path" '.[$path] | {narHash, narSize}')"
jq -n -S --arg version "$version" --arg revision "$revision" --arg system "$system" \
  --argjson cli "$cli_info" --argjson payload "$payload_info" \
  '{version: $version, revision: $revision, system: $system,
    outputs: {nagarectl: $cli, "nagare-platform": $payload}}' > "$out/nix-output-$system.json"

./scripts/rehearse-clone-free-release.sh --version "$version" \
  --flake-ref "git+file://$PWD?rev=$rev" --output "$out/clone-free-$system.json"
echo "release-native: $system attachments for $version at $rev in $out"
