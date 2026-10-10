#!/usr/bin/env bash
# Generation 2 (G2): change the source after the G1 backup so a restore of the
# pinned G1 snapshot is distinguishable from "latest".
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/env.sh"
. "$here/lib.sh"

k -n app exec deploy/writer -- sh -ec '
  echo "document 1 generation 2" > /files/docs/doc-1.txt
  rm /files/docs/doc-2.txt
  echo "document 101 generation 2" > /files/docs/doc-101.txt
'
k -n app exec pg-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U postgres -d appdb -v ON_ERROR_STOP=1 -c "
  update items set body = '\''changed'\'' where id = 1;
  insert into items select g, md5(g::text) from generate_series(1001, 1100) g;"'
files_manifest >"$EVAL_STATE/k8up/g2-files.sha256"
pg_fingerprint >"$EVAL_STATE/k8up/g2-pg.txt"
cat "$EVAL_STATE/k8up/g2-pg.txt"
