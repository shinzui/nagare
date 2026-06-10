#!/usr/bin/env bash
# scripts/backup-postgres.sh (EP-7 M2) — dump the host Postgres and upload to the
# GCS backup bucket. Runs on the NixOS host (via a systemd timer) or manually
# from the dev shell. Auth to GCS uses the VM's attached service account (ADC);
# no key files.
set -euo pipefail

# Load the target profile and run the configurable, fail-closed project-isolation
# preflight (EP-60). Refuses to run unless gcloud's active project equals the
# configured TARGET_PROJECT.
source "$(dirname "$0")/lib/target.sh"
_require_target_project

BUCKET="${BACKUP_BUCKET:-${NAGARE_BACKUP_BUCKET:?set BACKUP_BUCKET or NAGARE_BACKUP_BUCKET to the backup bucket name}}"
DB="${PGDATABASE:-notes}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/var/lib/nagare/backups/postgres-${DB}-${STAMP}.sql.gz"

mkdir -p /var/lib/nagare/backups
pg_dump --no-owner --no-privileges "$DB" | gzip -9 > "$OUT"

gsutil -o "GSUtil:parallel_composite_upload_threshold=150M" \
  cp "$OUT" "gs://${BUCKET}/postgres/$(basename "$OUT")"

echo "uploaded gs://${BUCKET}/postgres/$(basename "$OUT")"
