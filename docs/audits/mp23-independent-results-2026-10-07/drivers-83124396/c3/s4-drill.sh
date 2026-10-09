#!/usr/bin/env bash
# Checklist section 4 drill: PostgreSQL major-version upgrade, side by side (dump and restore into the
# new version), data verified, switch-over reviewed, old instance kept until the new one is proven,
# retired only after that; plus failed-upgrade returns to the old instance with no data loss.
# Usage: s4-drill.sh ROOT PHASE   (ROOT holds runctl.sh; phases run in order, each stops on failure)
# Phases: setup backup add probe-inplace fail1 copy fail2 recopy switch prove retire summary
set -uo pipefail
ROOT=$1; PH=$2; RUN=${S4_RUN:-$ROOT/runctl.sh}
APP=${S4_APP:-upg-app}; W=$ROOT/s4/$APP; A=$W/app; R=$W/reviews; E=$W/evidence; mkdir -p $A/nagare $R $E
NS=personal; OLD=${S4_OLD:-upg-pg}; NEW=${S4_NEW:-upg-pg18}; FROM=${S4_FROM:-17}; TO=${S4_TO:-18}
KCTX=${S4_KCTX:-local}; REG=${S4_REGISTRY:-k3d-registry.localhost:5000}; TAG=${S4_TAG:-s4}
URL=${S4_URL:-https://$APP.personal.127-0-0-1.sslip.io}
IMG_ARCHIVE=${S4_IMAGE_ARCHIVE:-$ROOT/images/scenario-a.tar}
K() { command kubectl --context $KCTX "$@"; }
die() { echo "S4 FAILED [$PH]: $*"; exit 1; }
log() { echo "== $(date -u +%H:%M:%S) $*" | tee -a $E/timeline.txt; }
stamp() { date -u +%FT%TZ > $E/$1.t; }
# SQL in a database pod as its own owner (official image: POSTGRES_USER, POSTGRES_DB in env).
Q() { local pod=$1-0; shift; K -n $NS exec $pod -- sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -v ON_ERROR_STOP=1 -tA -c \"$*\""; }
get() { curl -sk -m 15 ${S4_RESOLVE:+--resolve $S4_RESOLVE} -o $E/http.body -w "%{http_code}" "$URL$1"; }
rows() { Q $1 "select count(*)||':'||coalesce(max(id),0) from hits"; }
# Content fingerprint of every user table plus the hits sequence.
fp() { Q $1 "select string_agg(t||'='||n, ' ' order by t) from (select 'hits' t, (select md5(coalesce(string_agg(h::text, '|' order by h.id), '')) from hits h) n union all select 'hits_id_seq', (select last_value::text from hits_id_seq)) x"; }
# Fence and unfence run from the maintenance database `postgres`, so a read-only target cannot block them.
QM() { local pod=$1-0; shift; K -n $NS exec $pod -- sh -c "psql -U \"\$POSTGRES_USER\" -d postgres -v ON_ERROR_STOP=1 -tA -c \"$*\""; }
fence() { QM $1 "alter database \\\"\$POSTGRES_DB\\\" set default_transaction_read_only = on" >/dev/null && QM $1 "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = '\$POSTGRES_DB' and pid <> pg_backend_pid()" >/dev/null; }
unfence() { QM $1 "alter database \\\"\$POSTGRES_DB\\\" reset default_transaction_read_only" >/dev/null; }
readonly_of() { QM $1 "select coalesce((select array_to_string(setconfig, ',') from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase where d.datname = '\$POSTGRES_DB' and s.setrole = 0), 'writable')"; }
# Dump the old instance with the NEW major's pg_dump (PostgreSQL's recommendation) and restore it into
# the new instance in one transaction that stops at the first error.
copy_old_to_new() {
  local pw; pw=$(K -n $NS get secret nagare-db-$OLD -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
  local olddb; olddb=$(K -n $NS get secret nagare-db-$OLD -o jsonpath='{.data.POSTGRES_DB}' | base64 -d)
  printf '%s\n' "$pw" | K -n $NS exec -i $NEW-0 -- sh -c "read -r P; PGPASSWORD=\"\$P\" pg_dump -h $OLD.$NS.svc.cluster.local -U \"\$POSTGRES_USER\" -d $olddb --no-owner --no-privileges > /tmp/s4-dump.sql && pg_dump --version && sha256sum /tmp/s4-dump.sql && psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -q -v ON_ERROR_STOP=1 --single-transaction -f /tmp/s4-dump.sql; rc=\$?; rm -f /tmp/s4-dump.sql; exit \$rc"
}
# Application config: databases = list of name:version, service bound to one of them.
gen() { # out dbs bind
  local dbs=""; for d in $2; do dbs="$dbs${dbs:+, }(\"${d%%:*}\", \"${d#*:}\")"; done
  cat > $A/nagare/Config.hs <<EOF
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Section 4 drill application: the scenario-a image bound to one of its PostgreSQL databases.
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Build (BuildSpec (..))
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Database qualified as DB
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (RetentionPolicy (..), mkImageRef, mkNamespace, mkQuantity, mkServiceName)
import System.Environment (lookupEnv)

postgres :: (Text, Text) -> Either Text DB.Database
postgres (n, v) = do
  name' <- DB.mkDatabaseName n
  version' <- DB.mkEngineVersion DB.Postgres v
  namespace' <- mkNamespace "personal"
  size' <- mkQuantity "1Gi"
  pure
    DB.Database
      { DB.name = name'
      , DB.logicalKey = Nothing
      , DB.engine = DB.Postgres
      , DB.version = version'
      , DB.namespace = namespace'
      , DB.size = size'
      , DB.resources = Nothing
      , DB.retention = Retain
      }

applicationConfig :: Text -> Either Text Application
applicationConfig registry = do
  appName <- mkServiceName "$APP"
  namespace' <- mkNamespace "personal"
  image' <- mkImageRef (registry <> "/$APP")
  databases' <- traverse postgres [$dbs]
  bound <- DB.mkDatabaseName "$3"
  web <- webService "$APP" (registry <> "/$APP")
  dockerfile <- mkFilePathText "Dockerfile"
  context <- mkFilePathText "."
  mkApplication
    Application
      { name = appName
      , logicalKey = Nothing
      , namespace = namespace'
      , image = image'
      , env = Map.empty
      , databases = databases'
      , brokers = []
      , access = Nothing
      , service =
          Just
            ( web
                & #build .~ DockerfileBuild {dockerfile = dockerfile, context = context, buildArgs = Map.empty}
                & #databases .~ [bound]
            )
      , workers = []
      , tasks = []
      }

main :: IO ()
main = do
  -- Artifact Registry images live at <host>/<project>/<repository> on a cloud context.
  host <- maybe "k3d-registry.localhost:5000" Text.pack <$> lookupEnv "NAGARE_REGISTRY_HOST"
  mode <- lookupEnv "NAGARE_MODE"
  project <- maybe "" Text.pack <$> lookupEnv "CLOUDSDK_CORE_PROJECT"
  repository <- maybe "" Text.pack <$> lookupEnv "NAGARE_ARTIFACT_REGISTRY_ID"
  let registry = if mode == Just "cloud" && not (Text.null project) && not (Text.null repository) then host <> "/" <> project <> "/" <> repository else host
  either (ioError . userError . Text.unpack) emitApplication (applicationConfig registry)
EOF
  cp $A/nagare/Config.hs $W/config-$1.hs
}
deploy() { # name dbs bind [extra plan flags...]  (plan, keep the review text, apply)
  gen $1 "$2" $3
  local rec=""; for d in $2; do rec="$rec --database-recovery ${d%%:*}=${d%%:*}:v1"; done
  $RUN app deploy -f $A/nagare/Config.hs --tag $TAG --image-resource publication:app-image-$APP-$TAG/$APP-$TAG/oci-image $rec "${@:4}" --save-plan $R/$1 > $R/$1.plan.log 2>&1 || die "$1 plan: $(tail -2 $R/$1.plan.log | tr '\n' ' ')"
  cp $R/$1.plan.log $E/review-$1.txt
  $RUN inventory apply $R/$1 --yes > $R/$1.apply.log 2>&1 || die "$1 apply: $(tail -2 $R/$1.apply.log | tr '\n' ' ')"
  echo "$1: $(tail -1 $R/$1.apply.log)" | tee -a $E/timeline.txt
}
bound_host() { K -n $NS get ksvc $APP -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name=="POSTGRES_HOST") | .value'; }
wait_ready() { for i in $(seq 1 60); do [ "$(get /)" = 200 ] && return 0; sleep 3; done; return 1; }
idle() { [ "$($RUN inventory status --json 2>/dev/null | jq -r .activeTransaction)" = null ] || die "an inventory transaction is active"; }

idle
case $PH in
setup)
  cp /private/tmp/nagare-cand-83124396-src/fixtures/inventory-release/local/apps/scenario-a/{Dockerfile,app.py} $A/
  log "publish the drill image"
  $RUN app image-plan --archive $IMG_ARCHIVE --destination $REG/$APP:$TAG --key $APP-$TAG --save-plan $R/image > $R/image.log 2>&1 || die "image plan: $(tail -1 $R/image.log)"
  $RUN inventory apply $R/image --yes >> $R/image.log 2>&1 || die "image apply: $(tail -1 $R/image.log)"
  log "deploy $APP on PostgreSQL $FROM"
  deploy v1-old "$OLD:$FROM" $OLD
  wait_ready || die "app not ready"
  for i in 1 2 3 4 5; do [ "$(get /add)" = 200 ] || die "seed /add $i"; done
  Q $OLD "select version()" > $E/old-version.txt; rows $OLD > $E/rows-seeded.txt
  log "seeded $(cat $E/rows-seeded.txt) on $(cut -c1-16 $E/old-version.txt)"
  ;;
backup)
  log "fresh reviewed backup of the old instance, proven by an isolated restore"
  [ "$(get /add)" = 200 ] || die "pre-backup write"; rows $OLD > $E/rows-at-backup.txt
  $RUN db backup $OLD --backup-id s4pre --save-plan $R/backup > $R/backup.log 2>&1 && $RUN inventory apply $R/backup --yes >> $R/backup.log 2>&1 || die "backup: $(tail -1 $R/backup.log)"
  $RUN db restore $OLD s4pre --restore-id s4pre --save-plan $R/restore > $R/restore.log 2>&1 && $RUN inventory apply $R/restore --yes >> $R/restore.log 2>&1 || die "restore: $(tail -1 $R/restore.log)"
  K -n $NS exec $OLD-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "'"${OLD}_restore_s4pre"'" -tA -c "select count(*)||chr(58)||coalesce(max(id),0) from hits"' > $E/rows-restored.txt || die "read scratch restore"
  [ "$(cat $E/rows-restored.txt)" = "$(cat $E/rows-at-backup.txt)" ] || die "scratch restore $(cat $E/rows-restored.txt) != source $(cat $E/rows-at-backup.txt)"
  log "backup s4pre restored with $(cat $E/rows-restored.txt) rows = source"
  ;;
add)
  log "add the new PostgreSQL $TO instance beside the old one; binding unchanged"
  deploy v2-both-old "$OLD:$FROM $NEW:$TO" $OLD
  for i in $(seq 1 60); do Q $NEW "select 1" >/dev/null 2>&1 && break; sleep 3; done
  Q $NEW "select version()" > $E/new-version.txt || die "new instance not reachable"
  [ "$(bound_host)" = "$OLD.$NS.svc.cluster.local" ] || die "binding moved: $(bound_host)"
  [ "$(get /add)" = 200 ] || die "app write during add"
  log "new instance $(cut -c1-16 $E/new-version.txt); app still on $(bound_host)"
  ;;
probe-inplace)
  log "probe: an in-place major change of the old instance must not be applicable"
  gen inplace "$OLD:$TO $NEW:$TO" $OLD
  $RUN app deploy -f $A/nagare/Config.hs --tag $TAG --image-resource publication:app-image-$APP-$TAG/$APP-$TAG/oci-image --database-recovery $OLD=$OLD:v1 --database-recovery $NEW=$NEW:v1 --save-plan $R/inplace > $R/inplace.log 2>&1; rc=$?
  cp $R/inplace.log $E/probe-inplace.txt; echo "exit=$rc" >> $E/probe-inplace.txt
  log "in-place plan exit=$rc: $(grep -v warning $R/inplace.log | tail -2 | tr '\n' ' ' | cut -c1-240)"
  [ $rc -ne 0 ] || echo "S4 NOTE: in-place major change was PLANNED (not applied); review $E/probe-inplace.txt"
  ;;
revert-inplace)
  # After `inventory close` of the stuck in-place transaction (scope kept), correct the spec back to
  # the old major and replace the stuck pod through a reviewed restart (runbook F78 exit).
  log "revert the in-place change: corrected spec, then reviewed restart"
  deploy v2b-revert "$OLD:$FROM $NEW:$TO" $OLD
  $RUN db restart $OLD --save-plan $R/restart-old > $R/restart-old.log 2>&1 || die "restart plan: $(tail -2 $R/restart-old.log | tr '\n' ' ')"
  cp $R/restart-old.log $E/review-restart-old.txt
  $RUN inventory apply $R/restart-old --yes >> $R/restart-old.log 2>&1 || die "restart apply: $(tail -2 $R/restart-old.log | tr '\n' ' ')"
  for i in $(seq 1 60); do Q $OLD "select 1" >/dev/null 2>&1 && break; sleep 3; done
  Q $OLD "select version()" > $E/old-version-after-revert.txt || die "old instance not back"
  wait_ready || die "app after revert"; [ "$(get /add)" = 200 ] || die "write after revert"
  log "old instance back on $(cut -c1-16 $E/old-version-after-revert.txt): rows $(rows $OLD) (before in-place: $(cat $E/inplace-rows-before.txt))"
  ;;
fail1)
  log "failed upgrade 1: restore into the new instance fails; return to the old instance"
  Q $NEW "create table hits (id text primary key)" >/dev/null || die "inject conflict"
  before=$(rows $OLD); stamp fail1-fence; fence $OLD || die fence
  code=$(get /add); [ "$code" != 200 ] || die "fenced old instance accepted a write"
  copy_old_to_new > $E/fail1-copy.log 2>&1 && die "the copy should have failed"
  log "copy refused as injected: $(grep -i error $E/fail1-copy.log | head -1 | cut -c1-160)"
  [ "$(Q $NEW "select count(*) from information_schema.tables where table_schema='public'")" = 1 ] || die "partial restore left objects in the new instance"
  unfence $OLD; stamp fail1-unfence; wait_ready || die "app after return"
  [ "$(get /add)" = 200 ] || die "write after return"
  after=$(rows $OLD); log "returned to the old instance: rows $before -> $after (fenced write refused with HTTP $code)"
  [ "${after%%:*}" -eq $(( ${before%%:*} + 1 )) ] || die "row count after return"
  Q $NEW "drop table hits" >/dev/null
  ;;
copy|recopy)
  log "$PH: fence the old instance, copy into the new one, verify"
  [ $PH = recopy ] && { unfence $NEW; Q $NEW "drop schema public cascade; create schema public" >/dev/null || die "reset new"; }
  stamp $PH-fence; fence $OLD || die fence
  [ "$(get /add)" != 200 ] || die "fenced old instance accepted a write"
  copy_old_to_new > $E/$PH-copy.log 2>&1 || die "copy: $(tail -3 $E/$PH-copy.log | tr '\n' ' ')"
  fence $NEW || die "fence new"
  fp $OLD > $E/$PH-fp-old.txt; fp $NEW > $E/$PH-fp-new.txt
  cmp -s $E/$PH-fp-old.txt $E/$PH-fp-new.txt || die "fingerprints differ: $(cat $E/$PH-fp-old.txt) vs $(cat $E/$PH-fp-new.txt)"
  log "verified: $(cat $E/$PH-fp-new.txt); both instances read-only"
  ;;
fail2)
  log "failed upgrade 2: after the reviewed switch-over the new instance is rejected; reviewed switch back"
  deploy v3-switch-new "$OLD:$FROM $NEW:$TO" $NEW
  [ "$(bound_host)" = "$NEW.$NS.svc.cluster.local" ] || die "switch did not bind the new instance"
  deploy v4-switch-back "$OLD:$FROM $NEW:$TO" $OLD
  [ "$(bound_host)" = "$OLD.$NS.svc.cluster.local" ] || die "switch back did not bind the old instance"
  unfence $OLD; stamp fail2-unfence; wait_ready || die "app after switch back"
  before=$(cut -d' ' -f1 $E/copy-fp-old.txt); [ "$(get /add)" = 200 ] || die "write after switch back"
  log "returned to the old instance: $(rows $OLD); new instance never accepted a write ($(readonly_of $NEW))"
  ;;
switch)
  log "reviewed switch-over to the new instance"
  deploy v5-switch-new "$OLD:$FROM $NEW:$TO" $NEW
  [ "$(bound_host)" = "$NEW.$NS.svc.cluster.local" ] || die "switch did not bind the new instance"
  unfence $NEW; stamp switch-unfence; wait_ready || die "app on the new instance"
  n0=$(rows $NEW); [ "$(get /add)" = 200 ] || die "write on the new instance"; n1=$(rows $NEW)
  log "app on PostgreSQL $TO: rows $n0 -> $n1; old instance kept read-only ($(readonly_of $OLD))"
  ;;
prove)
  log "prove the new instance: reviewed backup and isolated restore"
  [ "$(get /add)" = 200 ] || die "write"; rows $NEW > $E/rows-new-at-backup.txt
  $RUN db backup $NEW --backup-id s4post --save-plan $R/backup-new > $R/backup-new.log 2>&1 && $RUN inventory apply $R/backup-new --yes >> $R/backup-new.log 2>&1 || die "backup new: $(tail -1 $R/backup-new.log)"
  $RUN db restore $NEW s4post --restore-id s4post --save-plan $R/restore-new > $R/restore-new.log 2>&1 && $RUN inventory apply $R/restore-new --yes >> $R/restore-new.log 2>&1 || die "restore new: $(tail -1 $R/restore-new.log)"
  K -n $NS exec $NEW-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "'"${NEW}_restore_s4post"'" -tA -c "select count(*)||chr(58)||coalesce(max(id),0) from hits"' > $E/rows-new-restored.txt || die "read new scratch"
  [ "$(cat $E/rows-new-restored.txt)" = "$(cat $E/rows-new-at-backup.txt)" ] || die "new scratch restore differs"
  log "new instance backup s4post restored with $(cat $E/rows-new-restored.txt) rows = source"
  ;;
retire)
  log "retire the old instance only now (reviewed; retention keeps its volume)"
  # The pre-upgrade backup and its proof restore consume the old instance: retire (retain) them first.
  if [ ! -f $R/retire-consumers.done ]; then
    $RUN inventory retire --scope standalone:database-backup-$NS-$OLD-s4pre --scope standalone:database-restore-$NS-$OLD-s4pre --out $R/retire-consumers > $R/retire-consumers.log 2>&1 || die "retire consumers plan: $(grep -v warning $R/retire-consumers.log | tail -2 | tr '\n' ' ' | cut -c1-400)"
    cp $R/retire-consumers.log $E/review-retire-consumers.txt
    $RUN inventory apply $R/retire-consumers --yes >> $R/retire-consumers.log 2>&1 || die "retire consumers apply: $(tail -1 $R/retire-consumers.log)"
    touch $R/retire-consumers.done; log "consumers retired: $(tail -1 $R/retire-consumers.log)"
  fi
  deploy v6-new-only "$NEW:$TO" $NEW --retire-database $OLD
  K -n $NS get pvc -o name > $E/pvcs-after-retire.txt; K -n $NS get sts -o name > $E/sts-after-retire.txt
  [ "$(get /add)" = 200 ] || die "write after retirement"
  log "after retirement: old volume $(grep -c "data-$OLD-0\|$OLD" $E/pvcs-after-retire.txt) PVC match(es); old StatefulSet $(grep -c "/$OLD\$" $E/sts-after-retire.txt); app rows $(rows $NEW)"
  ;;
*) die "unknown phase" ;;
esac
echo "PHASE-OK $PH"
