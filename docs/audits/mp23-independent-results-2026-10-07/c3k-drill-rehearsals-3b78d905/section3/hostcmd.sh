#!/usr/bin/env bash
# Run one read-only command on the c3k host over project-confined IAP, with the operator root's environment.
set -euo pipefail
src=$(sed -n '/^args=(/,/^)/p' /Users/shinzui/.local/state/nagare-verify/mp23-c3k/runctl.sh)
root=/Users/shinzui/.local/state/nagare-verify/mp23-c3k; eval "$src"
exec env -i "${args[@]}" NAGARE_CONTEXT=mp23-c3k bash /Users/shinzui/.local/state/nagare-verify/mp23-c3k/state/nagare/mp23-c3k/platform/nagare-0.4.0-3b78d905a7db-cc818380cd19b931/scripts/iap-ssh.sh ssh nagare-c3-1010 -- "$@"
