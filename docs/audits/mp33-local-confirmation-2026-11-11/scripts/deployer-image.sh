#!/usr/bin/env bash
# The arm64 tooling package has no platform payload (EP-253); add the packaged one from the
# same revision's darwin nagarectl, as the x86_64 package carries it.
set -euo pipefail
R=$HOME/.local/state/nagare/drills/mp33-final
export DOCKER_HOST=unix://$HOME/.colima/nagare-c4-amd64/docker.sock
PKG="$1"; REV="$2"
ROOT="$(sed -n "s/.*NAGARE_PLATFORM_ROOT=\${NAGARE_PLATFORM_ROOT-'\([^']*\)'}.*/\1/p" "$PKG/bin/nagarectl" | head -1)"
[ -f "$ROOT/release.json" ] || { echo "no payload at $ROOT" >&2; exit 1; }
B="$R/deployer-image"; rm -rf "$B"; mkdir -p "$B"; cp -RL "$ROOT" "$B/nagare"; chmod -R u+w "$B/nagare"
printf 'FROM nagarectl-linux:%s\nCOPY nagare /opt/nagare/share/nagare\nENV NAGARE_PLATFORM_ROOT=/opt/nagare/share/nagare\n' "${REV:0:8}" > "$B/Dockerfile"
docker build -q -t "nagarectl-deployer:${REV:0:8}" "$B"
docker run --rm --read-only --tmpfs /work:uid=65532,gid=65532 "nagarectl-deployer:${REV:0:8}" -c 'mkdir -p $HOME $TMPDIR; nagarectl platform root --json'
echo "workstation payload: $ROOT"
