#!/usr/bin/env bash
# Run the section 3 drill phases in order; stop at the first failure.
K=/Users/shinzui/.local/state/nagare-verify/mp23-c3l
for p in ${S3_PHASES:-snap0 backup fail-a fail-a-verify apply-b backup-c apply-c}; do
  bash $K/s3-drill.sh $p > $K/s3/phase-$p.log 2>&1; rc=$?
  echo "$(date -u +%FT%TZ) phase $p rc=$rc $(tail -1 $K/s3/phase-$p.log | cut -c1-300)"
  [ $rc = 0 ] || exit 1
done
echo S3-ALL-OK
