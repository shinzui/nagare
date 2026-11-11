. "$(dirname "$0")/lib.sh"
step "P1 EP-251 D6/D7: move the bootstrapped context's inventory into its in-cluster object store"
run "$N" version --json
run OP inventory store status
run OP inventory store migrate --to object --dry-run
run OP inventory store migrate --to object --yes
grep -E 'NAGARE_INVENTORY_STORE' "$XDG_CONFIG_HOME/nagare/contexts/mp33.env"
run OP inventory store status
[ "$(OP inventory store status --json | jq -r .kind)" = object ] || { echo "UNEXPECTED: store is not object" >&2; exit 1; }
