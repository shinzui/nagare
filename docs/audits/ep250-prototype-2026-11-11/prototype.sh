#!/usr/bin/env bash
# EP-250 D1: on a throwaway local context, does the pinned En accept a second object type
# `delegation`, and does `delegation:D#viewer@group:T#member` plus a membership admit a
# member and deny a non-member? Measures a check that needs the second object.
set -euo pipefail
. "$(dirname "$0")/en-api.sh"
step() { printf '\n## %s\n' "$*"; }
step "the schema with a delegation object, applied to the throwaway En and restarted"
K -n nagare-system get configmap en-schema -o jsonpath='{.data.app\.en}' > "$R/en-schema-before.en"
cat > "$R/en-schema-after.en" <<'SCHEMA'
object user {}

object group {
  relation member: user
}

object app {
  relation viewer: user, group#member
  permission access = viewer
}

object delegation {
  relation viewer: user, group#member
  permission access = viewer
}
SCHEMA
K -n nagare-system create configmap en-schema --from-file=app.en="$R/en-schema-after.en" --dry-run=client -o yaml | K apply -f - >/dev/null
K -n nagare-system rollout restart deploy/en >/dev/null; K -n nagare-system rollout status deploy/en --timeout=180s
kill "$(cat "$R/en-forward.pid" 2>/dev/null)" 2>/dev/null || true; sleep 1
. "$(dirname "$0")/en-api.sh"
en GET /v1/schema | head -1 | jq -c '{origin, hash, delegation: (.source | contains("object delegation"))}'
tuple() { printf '{"object":{"objectType":"%s","objectId":"%s"},"relation":"%s","subject":%s,"caveat":null}' "$@"; }
user() { printf '{"kind":"id","objectType":"user","objectId":"%s"}' "$1"; }
step "a team with one member, and the team as viewer of delegation ci"
en POST /v1/relationships "{\"tuples\":[$(tuple group proto-eng member "$(user proto-alice)"),$(tuple delegation ci viewer '{"kind":"set","objectType":"group","objectId":"proto-eng","relation":"member"}')]}"
check() { # user object-type object-id
  en POST /v1/check "{\"consistency\":{\"mode\":\"fullyConsistent\"},\"context\":{\"values\":{}},\"subject\":$(user "$1"),\"permission\":\"access\",\"object\":{\"objectType\":\"$2\",\"objectId\":\"$3\"}}"
}
step "decisions"
printf 'member on delegation:ci: '; check proto-alice delegation ci | tr '\n' ' '; echo
printf 'outsider on delegation:ci: '; check proto-bob delegation ci | tr '\n' ' '; echo
printf 'member on app:docs.team-a (no direct grant): '; check proto-alice app docs.team-a.127-0-0-1.sslip.io | tr '\n' ' '; echo
step "latency: 20 fully consistent checks each, host only versus host then delegation"
t() { local s; s=$(date +%s%N); "$@" >/dev/null; echo $(( ($(date +%s%N) - s) / 1000 )); }
host=(); both=()
for _ in $(seq 1 20); do host+=("$(t check proto-alice app docs.team-a.127-0-0-1.sslip.io)"); both+=("$(( $(t check proto-alice app docs.team-a.127-0-0-1.sslip.io) + $(t check proto-alice delegation ci) ))"); done
median() { printf '%s\n' "$@" | sort -n | sed -n "$(( ($# + 1) / 2 ))p"; }
echo "median microseconds: host-only check $(median "${host[@]}"), host-then-delegation miss $(median "${both[@]}")"
step "cleanup: the prototype tuples and the original schema"
en POST /v1/relationships "{\"tuples\":[],\"deletes\":[$(tuple group proto-eng member "$(user proto-alice)"),$(tuple delegation ci viewer '{"kind":"set","objectType":"group","objectId":"proto-eng","relation":"member"}')]}" | tail -1
K -n nagare-system create configmap en-schema --from-file=app.en="$R/en-schema-before.en" --dry-run=client -o yaml | K apply -f - >/dev/null
K -n nagare-system rollout restart deploy/en >/dev/null; K -n nagare-system rollout status deploy/en --timeout=180s
kill "$(cat "$R/en-forward.pid" 2>/dev/null)" 2>/dev/null || true
