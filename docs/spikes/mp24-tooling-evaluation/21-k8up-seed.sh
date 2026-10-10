#!/usr/bin/env bash
# Seed the K8up fixture with known content, generation 1 (G1):
#   files: 100 deterministic text files plus one 128 MiB pseudo-random file;
#   appdb.items: rows 1..1000 with md5 bodies.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/env.sh"
. "$here/lib.sh"

k -n app exec deploy/writer -- sh -ec '
  mkdir -p /files/docs
  i=1; while [ $i -le 100 ]; do echo "document $i generation 1" > /files/docs/doc-$i.txt; i=$((i+1)); done
  head -c 134217728 /dev/urandom > /files/blob.bin
'
k -n app exec pg-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U postgres -d appdb -v ON_ERROR_STOP=1 -c "
  create table if not exists items (id int primary key, body text not null);
  insert into items select g, md5(g::text) from generate_series(1, 1000) g on conflict do nothing;"'

mkdir -p "$EVAL_STATE/k8up"
files_manifest >"$EVAL_STATE/k8up/g1-files.sha256"
pg_fingerprint >"$EVAL_STATE/k8up/g1-pg.txt"
wc -l <"$EVAL_STATE/k8up/g1-files.sha256"
cat "$EVAL_STATE/k8up/g1-pg.txt"
