#!/usr/bin/env bash
# MP-26 item 11: everything up to the tag, unattended (docs/runbooks/releases.md).
#
#   scripts/release-candidate.sh VERSION [--revision REV] [--rehearsal]
#
# The release gate, the transition rehearsal from the newest release the candidate accepts, both
# systems' native attachments, two byte-identical assemblies, the intranet on the candidate, and
# the rehearsal record landed on origin/master. --rehearsal runs every step but lands nothing.
# `just release-publish VERSION` takes the run from here. The logic is
# `nagare-harness release candidate` (cli/nagare-harness/src/Nagare/Harness/Release/Candidate.hs,
# EP-229).
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/harness.sh" release candidate "$@"
