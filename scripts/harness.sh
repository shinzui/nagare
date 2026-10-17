#!/usr/bin/env bash
# EP-200: run nagare-harness as Nix builds it from this checkout. The Nix store
# is safe under concurrent builds from several sessions; a shared
# cli/nagare-harness/dist-newstyle is not, so no gate recipe runs cabal in the
# checkout it was started from. The gates themselves run in gate slots.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out=$(nix build --no-link --print-out-paths "$root#nagare-harness")
exec "$out/bin/nagare-harness" "$@"
