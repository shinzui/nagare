#!/usr/bin/env bash
# Build the linux nagarectl image for REV natively in the Apple container and load it into the
# disposable daemon. Its nagarectl carries the deploy payload (EP-248), so no overlay is layered.
set -euo pipefail
REV="$1"; R=$HOME/.local/state/nagare/drills/ep248
export DOCKER_HOST=unix://$HOME/.colima/nagare-c4-amd64/docker.sock
container exec nagare-ep253-arm64 sh -c "cd /work/nagare && nix build --extra-experimental-features 'nix-command flakes' --accept-flake-config --impure --no-link --print-out-paths --expr '(import /work/nagare/docs/audits/ep248-local-confirmation-2026-11-11/scripts/image.nix { rev = \"$REV\"; })'" > "$R/image-path"
container exec nagare-ep253-arm64 cat "$(cat "$R/image-path")" | docker load
docker run --rm --read-only --tmpfs /work:uid=65532,gid=65532 "nagarectl-linux:${REV:0:8}" -c 'mkdir -p $HOME $TMPDIR; nagarectl version --json; nagarectl platform root --json'
printf '%s\n' "$REV" > "$R/revision"
