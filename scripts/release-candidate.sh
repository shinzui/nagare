#!/usr/bin/env bash
# MP-26 item 11: everything up to the tag (docs/runbooks/releases.md).
#
#   scripts/release-candidate.sh VERSION [--revision REV] [--run DIR] [--rehearsal]
#
# The landing check, the release images, the transition rehearsal from the newest release the
# candidate accepts, and the intranet on the candidate. A run belongs to one version and revision;
# a rerun keeps every step it already finished. --rehearsal leaves the intranet alone.
# `just release-publish VERSION` takes the run from here. The logic is
# `nagare-harness release candidate` (cli/nagare-harness/src/Nagare/Harness/Release/Candidate.hs).
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/harness.sh" release candidate "$@"
