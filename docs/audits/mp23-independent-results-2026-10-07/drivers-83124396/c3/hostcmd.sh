#!/usr/bin/env bash
# Run one read-only command on the c3m host over project-confined IAP, with the operator root's environment.
set -euo pipefail
src=$(sed -n '/^args=(/,/^)/p' /Users/shinzui/.local/state/nagare-verify/mp23-c3m/runctl.sh)
root=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; eval "$src"
exec env -i "${args[@]}" NAGARE_CONTEXT=mp23-c3m bash /Users/shinzui/.local/state/nagare-verify/mp23-c3m/state/nagare/mp23-c3m/platform/nagare-0.4.0-831243962c6b-78c420ae9040ca7d/scripts/iap-ssh.sh ssh nagare-c3-1012 -- "$@"
