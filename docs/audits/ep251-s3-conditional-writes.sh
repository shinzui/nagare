#!/usr/bin/env bash
# EP-251 D1: do the pinned local object store's conditional writes hold?
# Runs the exact MinIO server release the local bootstrap packages
# (scripts/publish-local-minio-images.sh) in a throwaway Apple container and
# checks If-None-Match: * and If-Match: <etag>, alone and under racing writers.
set -euo pipefail

release=RELEASE.2025-09-07T16-13-09Z
asset="minio.linux-arm64.${release}"
sha=5c83cd2cf151717ba0243f73e1c7802ff36e272b67144bdd7f1f7d684fd6f03d
port=19251
user=ep251admin
secret=ep251-secret-not-for-use
name=ep251-minio
endpoint="http://127.0.0.1:${port}"
rounds="${ROUNDS:-25}"

work="$(mktemp -d "${TMPDIR:-/tmp}/ep251-s3.XXXXXX")"
cleanup() { container stop "$name" >/dev/null 2>&1 || true; container rm "$name" >/dev/null 2>&1 || true; rm -rf -- "$work"; }
trap cleanup EXIT

gh release download "$release" --repo minio/minio --pattern "$asset" --dir "$work"
[[ "$(shasum -a 256 "$work/$asset" | cut -d ' ' -f 1)" == "$sha" ]] || { echo 'MinIO asset digest differs' >&2; exit 1; }
mv "$work/$asset" "$work/minio" && chmod 755 "$work/minio" && mkdir "$work/data"
container run -d --rm --name "$name" -p "${port}:9000" -v "$work:/w" \
  -e MINIO_ROOT_USER="$user" -e MINIO_ROOT_PASSWORD="$secret" \
  alpine:latest /w/minio server /w/data >/dev/null
for _ in $(seq 1 60); do curl -fsS "$endpoint/minio/health/ready" >/dev/null 2>&1 && break; sleep 1; done
echo "server: $(curl -fsS -o /dev/null -w '%{http_code}' "$endpoint/minio/health/ready") ready, $release"

s3() { curl -sS --aws-sigv4 "aws:amz:us-east-1:s3" --user "$user:$secret" "$@"; }
put() { # key body [header] -> status
  local key=$1 body=$2; shift 2
  s3 -o /dev/null -w '%{http_code}' -X PUT --data-binary "$body" "$@" "$endpoint/inventory/$key"
}
get() { s3 "$endpoint/inventory/$1"; }
etag() { s3 -o /dev/null -D - -I "$endpoint/inventory/$1" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}'; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1 ($2)"; else echo "FAIL $1: expected $3, got $2"; failed=1; fi; }
failed=0

check "create bucket" "$(s3 -o /dev/null -w '%{http_code}' -X PUT "$endpoint/inventory")" 200
check "create head if absent" "$(put head one -H 'If-None-Match: *')" 200
check "second create if absent is refused" "$(put head two -H 'If-None-Match: *')" 412
check "refused create left the object" "$(get head)" one
first="$(etag head)"
check "replace if the ETag matches" "$(put head two -H "If-Match: $first")" 200
check "replace with a stale ETag is refused" "$(put head three -H "If-Match: $first")" 412
check "refused replace left the object" "$(get head)" two
# MinIO answers a conditional replace of a missing key 404 NoSuchKey, not 412:
# the transport must classify both as a refused condition.
check "replace on a missing key is refused (404)" "$(put missing x -H 'If-Match: "00000000000000000000000000000000"')" 404
check "the refused replace created nothing" "$(s3 -o /dev/null -w '%{http_code}' "$endpoint/inventory/missing")" 404

race() { # mode round -> winners
  local key="race-$1-$2" condition
  if [[ "$1" == replace ]]; then
    put "$key" base -H 'If-None-Match: *' >/dev/null
    condition="If-Match: $(etag "$key")"
  else
    condition='If-None-Match: *'
  fi
  put "$key" writer-a -H "$condition" > "$work/a" &
  put "$key" writer-b -H "$condition" > "$work/b" &
  wait
  local a b final
  a="$(cat "$work/a")" b="$(cat "$work/b")" final="$(get "$key")"
  if [[ "$a/$b" == "200/412" && "$final" == writer-a ]] || [[ "$a/$b" == "412/200" && "$final" == writer-b ]]; then
    echo 1
  else
    echo "0 ($a/$b final=$final)"
  fi
}
for mode in create replace; do
  good=0
  for round in $(seq 1 "$rounds"); do
    result="$(race "$mode" "$round")"
    [[ "$result" == 1 ]] && good=$((good + 1)) || echo "race $mode $round: $result"
  done
  check "racing $mode: exactly one writer wins and its body stays, in $rounds rounds" "$good" "$rounds"
done

if [[ "$failed" == 0 ]]; then echo "result: conditional create and replace hold"; else echo "result: FAILED"; exit 1; fi
