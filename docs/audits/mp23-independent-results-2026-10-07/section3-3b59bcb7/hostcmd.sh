#!/usr/bin/env bash
# Run one read-only command on the c3l host over project-confined IAP, with the operator root's environment.
set -euo pipefail
src=$(sed -n '/^args=(/,/^)/p' /Users/shinzui/.local/state/nagare-verify/mp23-c3l/runctl.sh)
root=/Users/shinzui/.local/state/nagare-verify/mp23-c3l; eval "$src"
exec env -i "${args[@]}" NAGARE_CONTEXT=mp23-c3l bash /Users/shinzui/.local/state/nagare-verify/mp23-c3l/state/nagare/mp23-c3l/platform/nagare-0.4.0-3b59bcb7612d-9aa97a32fa69dc6b/scripts/iap-ssh.sh ssh nagare-c3-1011 -- "$@"
