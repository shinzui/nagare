#!/usr/bin/env bash
# When the mp23-c3m bootstrap converges: create the host helper, check the host, start the C3 chain.
M=/Users/shinzui/.local/state/nagare-verify/mp23-c3m
until grep -q 'loop exit=' $M/evidence/bootstrap-loop.out 2>/dev/null; do sleep 60; done
grep -q 'loop exit=0' $M/evidence/bootstrap-loop.out && grep -q 'bootstrap converged' $M/evidence/bootstrap-loop.out || { echo "BOOTSTRAP NOT CONVERGED"; tail -3 $M/evidence/bootstrap-loop.out; exit 1; }
P=$(command ls -d $M/state/nagare/mp23-c3m/platform/nagare-0.4.0-831243962c6b-* | head -1)
cat > $M/hostcmd.sh <<EOH
#!/usr/bin/env bash
# Run one read-only command on the c3m host over project-confined IAP, with the operator root's environment.
set -euo pipefail
src=\$(sed -n '/^args=(/,/^)/p' $M/runctl.sh)
root=$M; eval "\$src"
exec env -i "\${args[@]}" NAGARE_CONTEXT=mp23-c3m bash $P/scripts/iap-ssh.sh ssh nagare-c3-1012 -- "\$@"
EOH
chmod 700 $M/hostcmd.sh
timeout 150 $M/hostcmd.sh 'readlink -f /run/current-system; k3s --version | head -1; uname -r' 2>/dev/null | grep -v -i warning
cd $M && bash c3-chain.sh > /dev/null 2>&1
grep -E 'CHAIN-DONE|CHAIN STOPPED' $M/c3-chain.log | tail -1
