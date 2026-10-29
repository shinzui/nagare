#!/usr/bin/env bash
# EP-210 M5: move the intranet to a release candidate, or pin it to the published tag
# (docs/runbooks/releases.md). `just release-candidate` runs the first form after assembly and
# `just release-publish` the second after the public flake check.
#
#   scripts/release-intranet.sh VERSION [--run DIR]             the candidate
#   scripts/release-intranet.sh VERSION [--run DIR] --pin-tag   the published tag
#
# The operator repository is NAGARE_RELEASE_OPERATOR_REPO (default: Mori's path for
# mori://tan/tan-ng-labs) and its context NAGARE_RELEASE_CONTEXT (default intranet). The logic
# is `nagare-harness transition run` and `transition pin-tag`
# (cli/nagare-harness/src/Nagare/Harness/Release/Intranet.hs, EP-229).
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/harness.sh" transition run "$@"
