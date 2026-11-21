#!/usr/bin/env bash
# MP-26 item 11: publish the run `just release-candidate VERSION` left ready (docs/runbooks/releases.md).
#
#   scripts/release-publish.sh VERSION [--run DIR]
#
# It checks every proof first (the run's candidate, the intranet record, the rehearsal record, the
# previous release), signs the tag, has the candidate's own CLI review the notes and rehearsal record
# from a checkout of the tag, then pushes only the tag, publishes, checks the public flake and pins
# the operator repository to the tag. The logic is `nagare-harness release publish`
# (cli/nagare-harness/src/Nagare/Harness/Release/Publish.hs, MasterPlan 37 D3).
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/harness.sh" release publish "$@"
