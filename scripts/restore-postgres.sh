#!/usr/bin/env bash
# scripts/restore-postgres.sh (EP-7 M2) — restore a pg_dump from GCS into a
# SCRATCH database, never over the live db. Prints a row count to compare.
set -euo pipefail
PROJECT=tan-nb-exp
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  exit 1
fi
BUCKET="${BACKUP_BUCKET:?set BACKUP_BUCKET}"
OBJECT="${1:?usage: restore-postgres.sh gs://BUCKET/postgres/<dump>.sql.gz}"
SCRATCH_DB="${SCRATCH_DB:-notes_restore_scratch}"
TMP="$(mktemp --suffix=.sql.gz)"
gsutil cp "$OBJECT" "$TMP"
dropdb --if-exists "$SCRATCH_DB"
createdb "$SCRATCH_DB"
gunzip -c "$TMP" | psql "$SCRATCH_DB"
echo "restored into scratch db '$SCRATCH_DB'; row count of notes:"
psql -At "$SCRATCH_DB" -c "SELECT count(*) FROM notes;"
rm -f "$TMP"
