#!/usr/bin/env bash
# Checklist section 2 (no data loss) drill on mp23-c3j, candidate 3ae20f8c, following
# docs/user/backups-and-disaster-recovery.md "Total cluster loss: recover the data" (F82-A, with
# nagare-fix's 3b34c19a corrections). Phases:
#   prep     (cluster up)  seed a timestamped row; escrow every accepted database's signing key;
#                          capture freshness; wait for a scheduled backup created after the seed.
#   recover  (cluster GONE: VM and data disk deleted by exact name beforehand) from a FRESH operator
#                          root holding only private material (context profile, escrow files, sops
#                          rules; the age key stays where the operator keeps it): list the backups in
#                          GCS, verify newest-first with the escrow and the object store, fetch the
#                          exact generation, check its SHA-256, restore into a disposable PostgreSQL 18
#                          with ON_ERROR_STOP=1, compare the rows, record the times.
set -uo pipefail
G=/Users/shinzui/.local/state/nagare-verify/mp23-c3j; RUN=$G/runctl.sh
E=$G/pending-evidence/section2-drill; mkdir -p $E
export KUBECONFIG=$G/config/nagare/kubeconfigs/mp23-c3j.yaml CLOUDSDK_ACTIVE_CONFIG_NAME=labs CLOUDSDK_CORE_PROJECT=tan-ng-labs
export DOCKER_HOST=unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock
BUCKET=tan-ng-labs-c3-1009-pmkjjpp-backups; DB=scenario-pg
die() { echo "S2 FAILED: $*"; exit 1; }
quiet() { grep -v -E '^(  warning|warning: Application|context guard)' "$1" | tail -2 | tr '\n' ' ' | cut -c1-300; }
K() { command kubectl --context mp23-c3j "$@"; }
umask 077

prep() {
  date -u +%FT%TZ > $E/prep-start.txt
  # Seed a row the recovered copy must contain.
  MARK="s2-drill-$(date -u +%Y%m%dT%H%M%SZ)"; echo "$MARK" > $E/seed-mark.txt
  K -n personal exec $DB-0 -- sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -v ON_ERROR_STOP=1 -q -c \"insert into scenario_known values ((select coalesce(max(id),0)+1 from scenario_known), '$MARK')\"" > $E/seed.log 2>&1 || die "seed: $(tail -1 $E/seed.log)"
  date -u +%FT%TZ > $E/seed-time.txt
  K -n personal exec $DB-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "select id||'"'"'|'"'"'||v from scenario_known order by id"' > $E/source-rows.txt || die "read source rows"
  # Escrow every accepted database's signing key (re-run is refused only for a different escrow).
  $RUN inventory status --json 2>/dev/null | jq -r '[.findings[] | select(.resource|test("/backup-signing-key$")) | .resource | capture("^(?<k>[a-z]+):(?<s>[^/]+)/(?<n>[^/]+)/") | .n] | unique[]' > $E/databases.txt
  : > $E/escrow.txt
  while read -r d; do $RUN db escrow-signing-key "$d" > $E/escrow-$d.log 2>&1; echo "$d exit=$? $(quiet $E/escrow-$d.log)" >> $E/escrow.txt; done < $E/databases.txt
  find $G/config/nagare/cluster-secrets/mp23-c3j/backup-signing -name '*.sops.yaml' | sort > $E/escrow-files.txt
  cat $E/escrow.txt
  # Freshness, visible before a breach.
  $RUN server status > $E/server-status.txt 2>&1; echo "server status exit=$?" >> $E/server-status.txt
  $RUN db backup-receipts $DB --check-freshness > $E/freshness.txt 2>&1; echo "freshness exit=$?" >> $E/freshness.txt
  # Wait (bounded) for a scheduled backup object created after the seed.
  SEED=$(cat $E/seed-time.txt); deadline=$(( $(date +%s) + 1500 ))
  while :; do
    gcloud storage objects list "gs://$BUCKET/databases/$DB/*.sql.gz" --format=json > $E/objects-prep.json 2>/dev/null
    n=$(jq --arg s "$SEED" '[.[] | select(.creation_time[:19] > $s[:19])] | length' $E/objects-prep.json)
    [ "$n" -gt 0 ] && break; [ "$(date +%s)" -lt $deadline ] || die "no scheduled backup after the seed within 25 min"; sleep 30
  done
  sleep 60  # let its receipt land beside it
  date -u +%FT%TZ > $E/prep-end.txt; echo "PREP-OK seed=$SEED mark=$(cat $E/seed-mark.txt)"
}

recover() {
  [ "$(gcloud compute instances list --filter='name=nagare-c3-1009' --format='value(name)' 2>/dev/null)" = "" ] || die "the VM still exists; destroy the cluster first"
  date -u +%FT%TZ > $E/recover-start.txt; T0=$(date +%s)
  # Fresh operator root: only the private material an operator keeps off the machine.
  F=$G-s2-fresh; rm -rf $F; mkdir -p -m 700 $F/config/nagare/contexts $F/config/nagare/cluster-secrets/mp23-c3j $F/state $F/cache $F/work
  cp $G/config/nagare/contexts/mp23-c3j.env $F/config/nagare/contexts/
  cp -R $G/config/nagare/cluster-secrets/mp23-c3j/backup-signing $F/config/nagare/cluster-secrets/mp23-c3j/
  cp $G/config/nagare/cluster-secrets/.sops.yaml $F/config/nagare/cluster-secrets/
  sed "s#root=$G\$#root=$F#; s#\"\$root/age-key.txt\"#\"$G/age-key.txt\"#g" $RUN > $F/runctl.sh; chmod 700 $F/runctl.sh
  # 1. Choose: list candidates in the bucket, newest first; verify with escrow + object store only.
  gcloud storage objects list "gs://$BUCKET/databases/$DB/*.sql.gz" --format=json > $E/objects-recover.json || die "list"
  SEED=$(cat $E/seed-time.txt)
  jq -r --arg s "$SEED" '[.[] | select(.creation_time[:19] > $s[:19])] | sort_by(.creation_time) | reverse | .[] | (.name | capture("/(?<j>[0-9a-f-]{36})\\.sql\\.gz$").j)' $E/objects-recover.json > $E/candidates.txt
  JOB=""; while read -r j; do
    timeout 300 $F/runctl.sh db verify-escrowed-backup $DB --backup-id $j > $E/verify-$j.log 2>&1 && { JOB=$j; break; }
    echo "candidate $j refused: $(quiet $E/verify-$j.log)"
  done < $E/candidates.txt
  [ -n "$JOB" ] || die "no candidate after the seed verified"
  GEN=$(grep -oE 'version [0-9]+' $E/verify-$JOB.log | head -1 | awk '{print $2}')
  SHA=$(sed -n 's/^ *sha256: *\([0-9a-f]\{64\}\).*/\1/p' $E/verify-$JOB.log | head -1)
  # 2. Fetch exactly that generation and check its hash.
  gcloud storage cp "gs://$BUCKET/databases/$DB/$JOB.sql.gz#$GEN" $F/work/dump.sql.gz > /dev/null 2>&1 || die "download $JOB#$GEN"
  GOT=$(shasum -a 256 $F/work/dump.sql.gz | cut -c1-64); [ "$GOT" = "$SHA" ] || die "sha256 $GOT != printed $SHA"
  # 3. Restore into a disposable engine, stopping at the first error.
  N=s2-pg-recovered; docker rm -f $N > /dev/null 2>&1
  docker run -d --name $N -e POSTGRES_PASSWORD=drill postgres:18 > /dev/null || die "docker run"
  for i in $(seq 1 60); do docker exec $N pg_isready -U postgres > /dev/null 2>&1 && break; sleep 2; done
  docker exec $N createdb -U postgres recovered || die createdb
  gunzip -c $F/work/dump.sql.gz | docker exec -i $N psql -U postgres -d recovered -q -v ON_ERROR_STOP=1 > $E/restore-psql.log 2>&1 || die "restore: $(tail -2 $E/restore-psql.log | tr '\n' ' ')"
  # 4. Compare with what was written before the recovery point.
  docker exec $N psql -U postgres -d recovered -tA -c "select id||'|'||v from scenario_known order by id" > $E/recovered-rows.txt
  T1=$(date +%s); date -u +%FT%TZ > $E/recover-end.txt
  diff $E/source-rows.txt $E/recovered-rows.txt > $E/rows.diff && SAME=true || SAME=false
  docker rm -f $N > /dev/null 2>&1; rm -f $F/work/dump.sql.gz
  jq -n --arg job "$JOB" --arg gen "$GEN" --arg sha "$SHA" --arg seed "$SEED" --arg mark "$(cat $E/seed-mark.txt)" \
    --arg start "$(cat $E/recover-start.txt)" --arg end "$(cat $E/recover-end.txt)" --argjson secs $((T1-T0)) --argjson same $SAME \
    --arg verify "$(grep -v warning $E/verify-$JOB.log | tail -6 | tr '\n' ' ')" --arg rows "$(tr '\n' ' ' < $E/recovered-rows.txt)" \
    '{database:"personal/scenario-pg", backupJob:$job, gcsGeneration:$gen, sha256:$sha, seedTime:$seed, seedMark:$mark,
      verifyOutput:$verify, recoveredRows:$rows, rowsMatchSourceAtSeed:$same, recoveryStart:$start, recoveryEnd:$end, recoverySeconds:$secs,
      freshRoot:"context profile + escrow files + sops rules only; age key read from the operator location", clusterState:"VM nagare-c3-1009 and its data disk deleted"}' > $E/result.json
  cat $E/result.json; [ "$SAME" = true ] || die "recovered rows differ from the source at the seed"
  echo RECOVER-OK
}

case "${1:-}" in prep) prep ;; recover) recover ;; *) echo "usage: $0 prep|recover"; exit 2 ;; esac
