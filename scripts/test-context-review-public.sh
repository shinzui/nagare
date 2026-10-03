#!/usr/bin/env bash
# Local-control proof with a synthetic admitted head and provider-denial sentinels.
set -euo pipefail
nagarectl_bin="${1:?pass built nagarectl executable}"
root="$(mktemp -d "${TMPDIR:-/tmp}/nagare-context-review.XXXXXX")"
trap 'if test "$?" -eq 0; then rm -rf "$root"; else echo "Failed fixture retained at $root" >&2; fi' EXIT
export XDG_CONFIG_HOME="$root/config" XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache"
export NAGARE_PLATFORM_ROOT="$PWD"
mkdir -p "$XDG_CONFIG_HOME/nagare/contexts" "$XDG_STATE_HOME/nagare/fixture/inventory" "$root/bin"
profile="$XDG_CONFIG_HOME/nagare/contexts/fixture.env"
head="$XDG_STATE_HOME/nagare/fixture/inventory/head.json"
cat > "$profile" <<'PROFILE'
CLOUDSDK_CORE_PROJECT=project
NAGARE_MODE=local
NAGARE_PLATFORM_VERSION=0.4.0
PROFILE
python3 - "$head" <<'PY'
import json,sys
json.dump(dict(version=1,generation=1,sequence=0,binding=dict(identity='fixture',project='project'),clientIdentity='context-public',accepted=[],converged=[],activeTransaction=None,executorClaim=None),open(sys.argv[1],'w'),sort_keys=True,separators=(',',':'))
PY
chmod 600 "$profile" "$head"
cp "$head" "$root/head-before"
cp "$profile" "$root/profile-before"
for command in gcloud pulumi kubectl ssh; do
  cat > "$root/bin/$command" <<'DENY'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$XDG_STATE_HOME/provider-access"
exit 97
DENY
  chmod +x "$root/bin/$command"
done
export PATH="$root/bin:$PATH"
run() {
  "$nagarectl_bin" "$@" > "$root/output" 2>&1 || { cat "$root/output" >&2; exit 1; }
}
refuse() {
  if "$nagarectl_bin" "$@" > "$root/output" 2>&1; then
    echo 'unsafe context control unexpectedly succeeded' >&2; exit 1
  fi
}
run context create fixture --force --machine-type e2-standard-4 --save-plan "$root/update"
cmp "$profile" "$root/profile-before"
mkdir -p "$root/other-state/nagare/fixture/inventory"
cp "$head" "$root/other-state/nagare/fixture/inventory/head.json"
if XDG_STATE_HOME="$root/other-state" "$nagarectl_bin" context apply "$root/update" --yes > "$root/output" 2>&1; then
  echo 'changed local history root unexpectedly accepted' >&2; exit 1
fi
grep -q 'local state root changed' "$root/output"
cmp "$profile" "$root/profile-before"
run context apply "$root/update" --yes
grep -q "NAGARE_MACHINE_TYPE='e2-standard-4'" "$profile"
cmp "$head" "$root/head-before"
run context apply "$root/update" --yes
refuse context create fixture --force --project foreign --save-plan "$root/foreign"
test ! -e "$root/foreign"
run context create fixture --force --machine-type e2-standard-2 --save-plan "$root/stale"
python3 - "$head" <<'PY'
import json,sys
path=sys.argv[1];head=json.load(open(path));head['generation']+=1;json.dump(head,open(path,'w'),sort_keys=True,separators=(',',':'))
PY
refuse context apply "$root/stale" --yes
grep -q 'history changed since review' "$root/output"
grep -q "NAGARE_MACHINE_TYPE='e2-standard-4'" "$profile"
cp "$head" "$root/head-removal"
cp "$profile" "$root/profile-removal"
run context delete fixture --save-plan "$root/remove"
test -e "$profile"
run context apply "$root/remove" --yes
test ! -e "$profile"
test -e "$profile.removed"
cmp "$head" "$root/head-removal"
refuse context create fixture --project foreign
grep -q 'retained removal authority' "$root/output"
refuse init fixture --project foreign --skip-preflight
grep -q 'retained removal authority' "$root/output"
run context restore "$root/remove" --yes
cmp "$profile" "$root/profile-removal"
test ! -e "$profile.removed"
run context apply "$root/remove" --yes
cmp "$profile" "$root/profile-removal"
printf '\n' >> "$root/update/context-review.json"
refuse context apply "$root/update" --yes
grep -q 'digest differs' "$root/output"
cmp "$head" "$root/head-removal"
test ! -e "$XDG_STATE_HOME/provider-access"
printf 'local context public review: update, stale/authority refusal, removal, restore and one-shot replay preserve history without provider access\n'
