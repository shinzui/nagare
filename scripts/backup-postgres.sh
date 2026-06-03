#!/usr/bin/env bash
# scripts/backup-postgres.sh (EP-7 M2) — dump the host Postgres and upload to the
# GCS backup bucket. Runs on the NixOS host (via a systemd timer) or manually
# from the dev shell. Auth to GCS uses the VM's attached service account (ADC);
# no key files.
set -euo pipefail

# --- Integration Point 9 preflight: refuse to run outside tan-nb-exp ---
PROJECT=tan-nb-exp
ACTIVE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ "$ACTIVE_PROJECT" != "$PROJECT" ]; then
  echo "refusing to run: gcloud active project is '${ACTIVE_PROJECT:-<unset>}', expected '$PROJECT'." >&2
  exit 1
fi

BUCKET="${BACKUP_BUCKET:?set BACKUP_BUCKET to the backupBucket stack output}"
DB="${PGDATABASE:-notes}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/var/lib/nagare/backups/postgres-${DB}-${STAMP}.sql.gz"

mkdir -p /var/lib/nagare/backups
pg_dump --no-owner --no-privileges "$DB" | gzip -9 > "$OUT"

gsutil -o "GSUtil:parallel_composite_upload_threshold=150M" \
  cp "$OUT" "gs://${BUCKET}/postgres/$(basename "$OUT")"

echo "uploaded gs://${BUCKET}/postgres/$(basename "$OUT")"
