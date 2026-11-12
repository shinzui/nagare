#!/usr/bin/env bash
# EP-257 M1: run app-owned.sql against a disposable postgres:18 server and compare the server's
# output with app-owned.expected and its observations with observed/postgres-app-owned-*.json.
# `--record` rewrites them instead.
#
# Uses Apple's `container` tool; set CONTAINER=docker to use Docker instead. The server is
# removed on exit.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
sql="$here/app-owned.sql"
expected="$here/app-owned.expected"
runtime="${CONTAINER:-container}"
image="${POSTGRES_IMAGE:-postgres:18}"
name="nagare-app-owned-fixture-$$"
record=false
[[ "${1:-}" == "--record" ]] && record=true

cleanup() { "$runtime" rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

"$runtime" run -d --name "$name" -e POSTGRES_PASSWORD=fixture -e POSTGRES_DB=smoke_pg "$image" >/dev/null
for _ in $(seq 1 60); do
  if "$runtime" exec "$name" pg_isready -U postgres -d smoke_pg >/dev/null 2>&1 &&
    "$runtime" exec "$name" psql -X -q -U postgres -d smoke_pg -c 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

actual="$(mktemp)"
trap 'cleanup; rm -f "$actual"' EXIT
"$runtime" exec "$name" psql -X -A -t -U postgres -d smoke_pg -c 'SELECT current_setting($$server_version_num$$)::int / 10000' |
  sed 's/^/-- server major version: /' >"$actual"

# Split the fixture into steps on "-- step: USER DATABASE" and run each as its own session. Both
# output streams are merged unbuffered inside the container, so errors stay next to their statement.
step_user=""
step_db=""
step_body=""
run_step() {
  [[ -z "$step_user" ]] && return 0
  {
    printf '\n-- step: %s %s\n' "$step_user" "$step_db"
    printf '%s\n' "$step_body" |
      "$runtime" exec -i "$name" sh -c 'exec stdbuf -o0 -e0 psql -X -a -v ON_ERROR_STOP=0 -U "$1" -d "$2" 2>&1' \
        sh "$step_user" "$step_db" |
      sed -e 's/psql:<stdin>:[0-9]*: //' || true
  } >>"$actual"
}
# The rendered SQL files go into the container, so a shell step can run them.
for file in "$here"/app-owned-*.sql; do
  "$runtime" exec -i "$name" sh -c "cat > /tmp/$(basename "$file")" <"$file"
done
observe() {
  local query="$here/$1" output="$here/observed/$2" answer
  answer="$("$runtime" exec -i "$name" psql -X -q -A -t -v ON_ERROR_STOP=1 -U postgres -d postgres <"$query")"
  if $record; then
    printf '%s\n' "$answer" >"$output"
  else
    printf '%s\n' "$answer" | diff -u "$output" - >&2 || echo "-- observe: $2 differs" >>"$actual"
  fi
  # A shell step reads the answer at /tmp/<name>, as a restore Job reads its role file.
  printf '%s\n' "$answer" | "$runtime" exec -i "$name" sh -c "cat > /tmp/$2"
}
shell_step() {
  {
    printf '\n-- shell: %s\n' "$1"
    "$runtime" exec "$name" sh -c "{ $1; } 2>&1" | sed -e 's/psql:[^:]*:[0-9]*: //' || true
  } >>"$actual"
}
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^--\ shell:\ (.+)$ ]]; then
    run_step
    step_user=""
    shell_step "${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^--\ observe:\ ([^ ]+)\ ([^ ]+)$ ]]; then
    run_step
    step_user=""
    observe "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  elif [[ "$line" =~ ^--\ step:\ ([^ ]+)\ ([^ ]+)$ ]]; then
    run_step
    step_user="${BASH_REMATCH[1]}"
    step_db="${BASH_REMATCH[2]}"
    step_body=""
  elif [[ -n "$step_user" ]]; then
    step_body+="$line"$'\n'
  fi
done <"$sql"
run_step

if $record; then
  cp "$actual" "$expected"
  echo "recorded $expected"
elif diff -u "$expected" "$actual"; then
  echo "app-owned fixture: PASS"
else
  echo "app-owned fixture: FAIL (output differs from $expected)" >&2
  exit 1
fi
