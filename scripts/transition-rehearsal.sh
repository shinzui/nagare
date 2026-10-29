#!/usr/bin/env bash
# EP-172 M3: rehearse the reviewed release transition of a local context, from a published
# source release to this payload, on a disposable Docker daemon; seed a database row before
# the move and read it back unchanged after it. Every step stops at its first refusal.
#
#   NAGARE_REHEARSAL_SOURCE=… NAGARE_REHEARSAL_TARGET=… DOCKER_HOST=… scripts/transition-rehearsal.sh
#
# `just release-rehearse` runs it from an empty environment. The logic is
# `nagare-harness transition drill` (cli/nagare-harness/src/Nagare/Harness/Release/TransitionDrill.hs,
# EP-229): it runs platform bootstrap plan and platform bootstrap apply on the source release,
# transition plan, inventory apply and platform transition commit on the candidate, and reads the
# transition_sentinel row back.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/harness.sh" transition drill "$@"
