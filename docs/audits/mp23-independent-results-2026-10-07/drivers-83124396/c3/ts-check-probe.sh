#!/usr/bin/env bash
# Hold a Tailscale SSH session to the c3m host open so its check URL stays approvable; exit 0 once approved.
M=/Users/shinzui/.local/state/nagare-verify/mp23-c3m; KH=$M/ts-probe-known-hosts
for i in $(seq 1 200); do
  : > $M/ts-check-url.txt
  ssh -o BatchMode=yes -o ConnectTimeout=900 -o ServerAliveInterval=15 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KH -o ControlMaster=no -o ControlPath=none deploy@100.108.102.52 true 2> >(tee -a $M/ts-probe.err | grep -o 'https://login.tailscale.com/a/[a-z0-9]*' > $M/ts-check-url.txt) && { echo "APPROVED $(date -u +%T)"; exit 0; }
  echo "$(date -u +%T) attempt $i not approved" >> $M/ts-probe.log; sleep 5
done
exit 1
