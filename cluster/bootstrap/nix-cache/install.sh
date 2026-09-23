#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/target.sh
source "$repo_root/scripts/lib/target.sh"
if [ "${NAGARE_NIX_CACHE_ENABLED:-0}" != 1 ]; then
  echo "Nix cache disabled for context '${NAGARE_CONTEXT}'; no resources changed."
  exit 0
fi
exec "$repo_root/scripts/run-reviewed-bootstrap.sh"
