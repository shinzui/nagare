#!/usr/bin/env bash
# MP-26 item 12: a release's upgrade rehearsal (EP-172) as one unattended command.
#
#   scripts/release-rehearse.sh REV PREV_VERSION
#
# It builds PREV_VERSION's packaged nagarectl and REV's, runs the transition drill on a disposable
# local context in the Colima profile nagare-mp23 from an empty environment whose PATH has no Helm,
# and writes docs/release-evidence/<rev>/transition-rehearsal.json, uncommitted, or
# NAGARE_RELEASE_REHEARSAL_RECORD. An existing record is kept. The logic is
# `nagare-harness transition rehearse` (cli/nagare-harness/src/Nagare/Harness/Release/Rehearse.hs,
# EP-229).
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/harness.sh" transition rehearse "$@"
