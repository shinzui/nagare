#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/target.sh
source "$repo_root/scripts/lib/target.sh"
if [ "${NAGARE_MODE:-cloud}" = local ]; then
  echo "error: auth-install.sh requires a cloud context" >&2
  exit 2
fi
exec "$repo_root/scripts/run-reviewed-bootstrap.sh"
