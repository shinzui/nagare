#!/usr/bin/env bash
set -euo pipefail
rev=3b59bcb7612d513bfd663c36c251f8454e615502
mkdir -p /etc/nix
cat > /etc/nix/nix.conf <<'CONF'
experimental-features = nix-command flakes
build-users-group =
sandbox = false
filter-syscalls = false
substituters = file:///c4/cache https://cache.nixos.org
require-sigs = false
always-allow-substitutes = true
CONF
nix profile install nixpkgs#jq >/dev/null 2>&1
git config --global safe.directory '*'
git config --global user.email c4@example.invalid
git config --global user.name c4
git -c init.defaultBranch=master clone -q /c4/nagare-3b59bcb7.bundle /work/nagare
cd /work/nagare
git checkout -q --detach "$rev"
test "$(git rev-parse HEAD)" = "$rev"
ref="git+file:///work/nagare?rev=$rev"
echo "system: $(nix eval --raw --impure --expr builtins.currentSystem)"
out=/c4/out/release-x86_64-linux; rm -rf "$out"; mkdir -p "$out"
nix profile install --priority 4 .#release-tools
nix profile install --priority 6 nixpkgs#gawk nixpkgs#gnused nixpkgs#gnugrep nixpkgs#findutils nixpkgs#diffutils >/dev/null 2>&1
bash scripts/check-release.sh --version 0.4.0 --output-dir "$out" --json > "$out/gate.json"
echo "check-release exit=0"
revision="$(jq -er '.revision' "$out/nagare-release-0.4.0.json")"
cli_path="$(nix build --no-link --print-out-paths .#nagarectl)"
payload_path="$(nix build --no-link --print-out-paths .#nagare-platform)"
cli_info="$(nix path-info --json --json-format 1 "$cli_path" | jq --arg path "$cli_path" '.[$path] | {narHash, narSize}')"
payload_info="$(nix path-info --json --json-format 1 "$payload_path" | jq --arg path "$payload_path" '.[$path] | {narHash, narSize}')"
jq -n -S --arg version 0.4.0 --arg revision "$revision" --arg system x86_64-linux \
  --argjson cli "$cli_info" --argjson payload "$payload_info" \
  '{version: $version, revision: $revision, system: $system,
    outputs: {nagarectl: $cli, "nagare-platform": $payload}}' > "$out/nix-output-x86_64-linux.json"
cat "$out/nix-output-x86_64-linux.json"
echo X86-RELEASE-DONE
