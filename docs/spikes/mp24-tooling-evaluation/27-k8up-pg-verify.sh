#!/usr/bin/env bash
# Apply 26-k8up-pg-dump-restore.yaml, load the fetched dump with pg_restore, and
# compare the isolated database with the G1 fingerprint and the live source.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/env.sh"
. "$here/lib.sh"
out="$EVAL_STATE/k8up/pg-dump-restore"
mkdir -p "$out"

k apply -f "$here/26-k8up-pg-dump-restore.yaml"
k -n restore wait --for=condition=Ready pod/pg-restore --timeout=240s
k -n restore logs pg-restore -c fetch | tee "$out/fetch.log"
k -n restore exec pg-restore -c pg -- sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -h 127.0.0.1 -U postgres -d appdb --no-owner /work/g1.dump'
pg_fingerprint restore pg-restore appdb | tee "$out/restored-pg.txt"
pg_fingerprint app pg-0 appdb | tee "$out/source-after-pg.txt"
cmp "$out/restored-pg.txt" "$EVAL_STATE/k8up/g1-pg.txt" && echo "PASS: isolated database == G1"
cmp "$out/source-after-pg.txt" "$EVAL_STATE/k8up/g2-pg.txt" && echo "PASS: source still == G2"
