#!/usr/bin/env bash
set -euo pipefail
rev=831243962c6b80f91da1028cdab8238ae6acdabd
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
git -c init.defaultBranch=master clone -q /c4/nagare-83124396.bundle /work/nagare
cd /work/nagare
git checkout -q --detach "$rev"
test "$(git rev-parse HEAD)" = "$rev"
ref="git+file:///work/nagare?rev=$rev"
echo "system: $(nix eval --raw --impure --expr builtins.currentSystem)"
nix --version
a=$(nix eval --raw "$ref#packages.x86_64-linux.nagarectl.outPath"); echo "nagarectl outPath: $a"
b=$(nix eval --raw "$ref#packages.x86_64-linux.nagare.outPath"); echo "nagare outPath: $b"
test "$a" = /nix/store/4ymd5gcpa2v1k3d20r8z1cp8l3w53smv-nagarectl-0.4.0
test "$b" = /nix/store/fssh7acx7cphlxv4bn9hk7xd467yjn9k-nagare-0.4.0
s=$(date +%s)
bash scripts/rehearse-clone-free-release.sh --version 0.4.0 --flake-ref "$ref" --output /c4/out/clone-free-x86_64-linux.json
echo "rehearsal exit=0 seconds=$(( $(date +%s) - s ))"
