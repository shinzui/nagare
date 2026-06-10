#!/usr/bin/env bash
# scripts/restore-sqlite.sh (EP-7 M2) — restore a Litestream-backed SQLite db
# into a SCRATCH file, never over a live db.
set -euo pipefail
source "$(dirname "$0")/lib/target.sh"
_require_target_project
BUCKET="${BACKUP_BUCKET:-${NAGARE_BACKUP_BUCKET:?set BACKUP_BUCKET or NAGARE_BACKUP_BUCKET}}"
SCRATCH="${1:-/tmp/restore-app.db}"
# -if-replica-exists exits 0 with no error when there is no backup yet.
litestream restore -if-replica-exists -o "$SCRATCH" "gcs://${BUCKET}/litestream/app.db"
echo "restored into $SCRATCH; row count:"
sqlite3 "$SCRATCH" "SELECT count(*) FROM notes;" 2>/dev/null || echo "(no notes table yet)"
