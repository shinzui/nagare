#!/usr/bin/env bash
# EP-248 D8/D10: bootstrap a disposable local context `ep248` on the nagare-c4-amd64 daemon.
set -euo pipefail
R=$HOME/.local/state/nagare/drills/ep248
export DOCKER_HOST=unix://$HOME/.colima/nagare-c4-amd64/docker.sock
export NAGARE_DRILL_NAGARECTL="${BOOTSTRAP_NAGARECTL:?the packaged nagarectl to bootstrap with}/bin/nagarectl"
export NAGARE_DRILL_ROOT=$R NAGARE_DRILL_CONTEXT=ep248 NAGARE_DRILL_BOOTSTRAP_ONLY=1 NAGARE_DRILL_RESET=1 NAGARE_DRILL_IMAGE_TAG=${BOOTSTRAP_IMAGE_TAG:-9577009}
exec bash "$HOME/Keikaku/bokuno/nagare/scripts/site-access-drill.sh"
