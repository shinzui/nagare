#!/usr/bin/env bash
# Inside an amd64 nixos/nix container with the work directory mounted at /work:
# clone the candidate from /work/candidate.bundle and run release-native.sh for
# x86_64-linux. Nix substitutes from the file cache /work/cache first, which the
# maintainer fills from the builder (docs/runbooks/releases.md).
set -euo pipefail

usage() { echo "usage: $0 REVISION VERSION" >&2; exit 2; }
[[ $# -eq 2 ]] || usage
rev="$1"
version="$2"

mkdir -p /etc/nix
cat > /etc/nix/nix.conf <<'CONF'
experimental-features = nix-command flakes
build-users-group =
sandbox = false
filter-syscalls = false
substituters = file:///work/cache https://cache.nixos.org
require-sigs = false
always-allow-substitutes = true
CONF
git config --global safe.directory '*'
git config --global user.email release@example.invalid
git config --global user.name release
git -c init.defaultBranch=master clone -q /work/candidate.bundle /tmp/nagare
cd /tmp/nagare
git checkout -q --detach "$rev"
[[ "$(git rev-parse HEAD)" == "$rev" ]]
nix profile install --priority 4 .#release-tools
nix profile install --priority 6 nixpkgs#jq nixpkgs#gawk nixpkgs#gnused nixpkgs#gnugrep nixpkgs#findutils nixpkgs#diffutils >/dev/null 2>&1
bash scripts/release-native.sh "$version" /work/out/x86_64-linux
