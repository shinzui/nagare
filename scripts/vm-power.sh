#!/usr/bin/env bash
# scripts/vm-power.sh (EP-97) — start/stop the target VM THROUGH the guardrail.
#
# `just vm-stop` / `just vm-start` used to run raw gcloud with no --project and
# no preflight, silently acting on whatever project gcloud defaulted to. This
# wrapper sources the shared resolver, runs the fail-closed preflight, and pins
# --project/--zone to the active context's values.
set -euo pipefail

if [ "$#" -ne 1 ] || { [ "$1" != "start" ] && [ "$1" != "stop" ]; }; then
  echo "usage: scripts/vm-power.sh <start|stop>" >&2
  exit 2
fi

# shellcheck source=scripts/lib/target.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/target.sh"
_require_target_project

exec gcloud --project="${TARGET_PROJECT}" compute instances "$1" \
  "${NAGARE_INSTANCE_NAME:-nagare-01}" --zone="${TARGET_ZONE}"
