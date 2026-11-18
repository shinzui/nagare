#!/usr/bin/env bash
# scripts/local-postgres-major-upgrade-drill.sh (EP-266 M3): a side-by-side PostgreSQL major
# upgrade of app databases on a shared server, natively, on a warm disposable local context.
#
#   1. server upg-17 at PostgreSQL 17, app databases ua-pg and ub-pg on it, a probe Worker
#      bound to each, and seeded rows written by each runtime user;
#   2. a fresh backup of each, ingested and restored into scratch, equal to its source;
#   3. server upg-18 at 18 and app databases ua-pg-v2 and ub-pg-v2 on it, the old ones kept;
#   4. ua: quiesce ua-pg, copy into ua-pg-v2 as its migration user, fingerprints equal, switch
#      ua-probe's binding by a reviewed deploy, a write through it lands on 18;
#   5. ua-pg-v2's own backup, ingested and restored into scratch, equal; only then ua-pg retires,
#      its data kept;
#   6. fail 1: the copy into ub-pg-v2 fails; ub-pg resumes and takes writes, every acknowledged
#      row present, ub-pg-v2 empty;
#   7. fail 2: ub is copied and switched, then rejected: a reviewed deploy of the old binding
#      and a resume return to ub-pg with every acknowledged row; ub-pg-v2 took no write;
#   8. pass.
#
# Usage (an empty environment; the root names the context, its kubeconfig and the reviews):
#   NAGARE_DRILL_ROOT=DIR NAGARE_DRILL_CONTEXT=NAME NAGARECTL=/path/to/packaged/nagarectl \
#     DOCKER_HOST=unix:///…/docker.sock scripts/local-postgres-major-upgrade-drill.sh
# NAGARE_DRILL_ROOT is a root a local bootstrap (scripts/site-access-drill.sh) left warm: the
# context, kubeconfig and payload are read from its config and state directories. A stopped run
# resumes on a rerun (scripts/lib/drill.sh); NAGARE_DRILL_FROM names the step (1 to 7).
# A passed run leaves ua-pg retired on upg-17, and a retired app database is not reopened, so the
# next run needs a new root (or NAGARE_DRILL_RESET on the bootstrap).
set -euo pipefail

: "${NAGARE_DRILL_ROOT:?the warm drill root}"
: "${NAGARE_DRILL_CONTEXT:?the mode=local context in that root}"
: "${DOCKER_HOST:?the disposable Docker daemon socket}"
ROOT="$NAGARE_DRILL_ROOT"
CTX="$NAGARE_DRILL_CONTEXT"
NAGARECTL="${NAGARECTL:-$(command -v nagarectl)}"
NS=personal
export XDG_CONFIG_HOME="$ROOT/config" XDG_STATE_HOME="$ROOT/state" XDG_CACHE_HOME="$ROOT/cache"
WORK="$ROOT/pg-major-upgrade"
mkdir -p "$WORK/config" "$WORK/images"

log() { printf '%s pg-major-upgrade drill: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "pg-major-upgrade drill: FAIL: $*" >&2; exit 1; }
N() { "$NAGARECTL" --context "$CTX" "$@"; }
n() { drill_saved N "$@"; }
# shellcheck source=scripts/lib/drill.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/drill.sh"
drill_init "$WORK/drill"
RUN="$DRILL_RUN"
REVIEWS="$DRILL_RUN_DIR/reviews"
apply() { drill_apply "$1"; }

# --- 0. the context is local and its kubeconfig reaches a loopback cluster ---
ctx_env="$(N context env)"
grep -Eqx "export NAGARE_MODE='?local'?" <<<"$ctx_env" || fail "context $CTX is not mode=local"
eval "$(grep -E '^export (NAGARE_REGISTRY_HOST|NAGARE_ARTIFACT_REGISTRY_ID|CLOUDSDK_CORE_PROJECT)=' <<<"$ctx_env")"
export KUBECONFIG="$XDG_CONFIG_HOME/nagare/kubeconfigs/$CTX.yaml"
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
case "$server" in https://127.0.0.1:*|https://0.0.0.0:*|https://localhost:*) ;; *) fail "kubeconfig server $server is not loopback" ;; esac
# Host-side publications go through this daemon's own registry forward, never a port another
# daemon's forward may hold.
forward="$(docker port registry-forward 5000/tcp 2>/dev/null | head -1)"
[ -n "$forward" ] || fail "this Docker daemon has no registry-forward container; bootstrap the root with scripts/site-access-drill.sh"
export NAGARE_LOCAL_REGISTRY_FORWARD="$forward"
log "context $CTX ($server), nagarectl $("$NAGARECTL" version | head -1), run $RUN"

secret() { kubectl -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" | base64 -d; }
expect() { [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"; }
refused() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$label was allowed"; fi; }
ready() { # server
  kubectl -n "$NS" rollout status "statefulset/$1" --timeout=300s >/dev/null
  for _ in $(seq 1 60); do kubectl -n "$NS" exec "$1-0" -- pg_isready -h 127.0.0.1 >/dev/null 2>&1 && return 0; sleep 2; done
  fail "server $1 is not ready"
}
# A migration user on its own server, through the Service (the image trusts loopback).
pg_as() { # server, app database, logical database, sql
  kubectl -n "$NS" exec "$1-0" -- env PGPASSWORD="$(secret "$2-migration" POSTGRES_PASSWORD)" \
    psql -h "$1" -U "$(secret "$2-migration" POSTGRES_USER)" -d "$3" -v ON_ERROR_STOP=1 -tAc "$4"
}
# The runtime user, from inside the probe Worker, through whatever binding it now has.
pg_rt() { kubectl -n "$NS" exec "deployment/$1" -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -tAc "$1"' sh "$2"; }
FP="SELECT count(*) || ':' || md5(coalesce(string_agg(id || '=' || v, ',' ORDER BY id), '')) FROM t"
probe_host() { kubectl -n "$NS" get deployment "$1" -o json | python3 -I -c '
import json, sys
for c in json.load(sys.stdin)["spec"]["template"]["spec"]["containers"]:
    for e in c.get("env", []):
        if e["name"] == "POSTGRES_HOST": print(e.get("value", ""))'; }

# --- the declarations ---
appdb_config() { # file, stage: old, both or final
  cat > "$1" <<EOF
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Nagare.Dsl.AppDatabase
import Nagare.Dsl.Config (emitAppDatabases)
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Types (mkAppDatabaseName, mkDatabaseName, mkNamespace)

ok :: Either Text a -> a
ok = either (error . show) id

stage :: Text
stage = "$2"

app :: Text -> Text -> Text -> AppDatabase
app name server db =
  AppDatabase
    { name = ok (mkAppDatabaseName name)
    , logicalKey = Nothing
    , server = ok (mkDatabaseName server)
    , engine = Postgres
    , namespace = ok (mkNamespace "personal")
    , logicalDatabases = ok (mapM mkLogicalDatabaseName (db :| []))
    , access = noAppDatabaseAccess
    , ownership = NagareManaged
    }

main :: IO ()
main =
  emitAppDatabases $
    -- ua-pg retires in step 5; declaring it again would reopen it.
    [app "ua-pg" "upg-17" "ua" | stage /= "final"]
      <> [app "ub-pg" "upg-17" "ub"]
      <> [app "ua-pg-v2" "upg-18" "ua" | stage /= "old"]
      <> [app "ub-pg-v2" "upg-18" "ub" | stage /= "old"]
EOF
}
for stage in old both final; do appdb_config "$WORK/config/AppDatabases-$stage.hs" "$stage"; done
plan_stage() { # stage
  if ! N db app-database plan --config "$WORK/config/AppDatabases-$1.hs" | grep -qx 'no operations'; then
    n db app-database plan --config "$WORK/config/AppDatabases-$1.hs" --save-plan "$REVIEWS/app-databases-$1" >/dev/null
    apply "$REVIEWS/app-databases-$1"
  fi
  expect "the $1 declarations converged" "$(N db app-database plan --config "$WORK/config/AppDatabases-$1.hs" 2>/dev/null | tail -1)" "no operations"
}

# A probe Worker on the published postgres image, bound to one app database.
publish() { # local image, repository; prints the accepted image resource
  local image="$1" repo="$2" digest key archive out
  digest="$(docker image inspect "$image" --format '{{.Id}}' | cut -d: -f2)"
  key="${repo}-${digest:0:12}"
  archive="$WORK/images/$key.tar"
  [ -s "$archive" ] || docker save "$image" -o "$archive"
  out="$(n app image-plan --archive "$archive" \
    --destination "${NAGARE_REGISTRY_HOST}/${CLOUDSDK_CORE_PROJECT}/${NAGARE_ARTIFACT_REGISTRY_ID}/${repo}:${digest:0:12}" \
    --key "$key" --save-plan "$REVIEWS/image-$repo")" || fail "plan the image $repo"
  apply "$REVIEWS/image-$repo" >&2
  printf '%s\n' "$out" | sed -n 's/^Image resource: //p' | tail -1
}
docker image inspect postgres:18 >/dev/null 2>&1 || docker pull postgres:18 >/dev/null
PG_IMAGE="$(publish postgres:18 upg-probe-pg)"
[ -n "$PG_IMAGE" ] || fail "the probe image review named no resource"
PG_TAG="$(docker image inspect postgres:18 --format '{{.Id}}' | cut -d: -f2 | cut -c1-12)"
bind_probe() { # worker, app database, review label
  mkdir -p "$WORK/config/$1-$2"
  cat > "$WORK/config/$1-$2/Config.hs" <<EOF
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Nagare.Dsl.Build (BuildSpec (PrebuiltImage), mkTag)
import Nagare.Dsl.Config (emitWorker)
import Nagare.Dsl.Types (appDatabaseBinding, mkAppDatabaseName)
import Nagare.Dsl.Worker (mkCommand, webWorker)

main :: IO ()
main = either (ioError . userError) emitWorker \$ do
  base <- webWorker "$1" "upg-probe-pg"
  tag <- first show (mkTag "$PG_TAG")
  cmd <- first show (mkCommand ["sleep", "infinity"])
  appdb <- first show (mkAppDatabaseName "$2")
  Right (base & #build .~ PrebuiltImage tag & #command .~ Just cmd & #appDatabases .~ [appDatabaseBinding appdb])
EOF
  n worker deploy -f "$WORK/config/$1-$2/Config.hs" --tag probe --image-resource "$PG_IMAGE" --save-plan "$REVIEWS/worker-$3" >/dev/null
  apply "$REVIEWS/worker-$3"
  kubectl -n "$NS" rollout status "deployment/$1" --timeout=300s >/dev/null
  case "$(probe_host "$1")" in "$(server_of "$2")"|"$(server_of "$2")".*) ;; *) fail "$1 is not bound to $(server_of "$2"): POSTGRES_HOST=$(probe_host "$1")" ;; esac
}
server_of() { case "$1" in *-v2) echo upg-18 ;; *) echo upg-17 ;; esac; }
quiesce() { n db app-database quiesce "$1" -n "$NS" --users runtime --save-plan "$REVIEWS/quiesce-$1-$2" >/dev/null; apply "$REVIEWS/quiesce-$1-$2"; }
resume() { n db app-database resume "$1" -n "$NS" --save-plan "$REVIEWS/resume-$1-$2" >/dev/null; apply "$REVIEWS/resume-$1-$2"; }
# The copy: the server administrator dumps the old logical database, and the new app
# database's migration user loads it in one transaction, so it owns what it loads.
copy() { # old app database, new app database, logical database, extra SQL appended
  kubectl -n "$NS" exec upg-17-0 -- sh -c 'pg_dump -U "$POSTGRES_USER" -d "$1" --no-owner --no-privileges' sh "$3" \
    | { cat; printf '%s\n' "$4"; } \
    | kubectl -n "$NS" exec -i upg-18-0 -- env PGPASSWORD="$(secret "$2-migration" POSTGRES_PASSWORD)" \
        psql -h upg-18 -U "$(secret "$2-migration" POSTGRES_USER)" -d "$3" -v ON_ERROR_STOP=1 --single-transaction -q
}
# A scheduled-format backup on demand, ingested, restored into scratch; prints the scratch name.
backup_restore() { # app database, logical database, id
  local job uid
  n db app-database backup "$1" -n "$NS" --backup-id "$3" --save-plan "$REVIEWS/backup-$1-$3" >/dev/null
  apply "$REVIEWS/backup-$1-$3"
  job="nagare-appdb-$1-$3"
  kubectl -n "$NS" wait --for=condition=complete "job/$job" --timeout=600s >/dev/null \
    || { kubectl -n "$NS" logs "job/$job" --all-containers --tail=20 >&2 || true; fail "backup $job did not complete"; }
  uid="$(kubectl -n "$NS" get job "$job" -o jsonpath='{.metadata.uid}')"
  n db app-database backup-receipts "$1" -n "$NS" --backup-id "$uid" --save-plan "$REVIEWS/ingest-$1-$3" >/dev/null
  apply "$REVIEWS/ingest-$1-$3"
  n db app-database restore "$1" -n "$NS" --backup-id "$uid" --restore-id "$3" --save-plan "$REVIEWS/restore-$1-$3" >/dev/null
  apply "$REVIEWS/restore-$1-$3"
  echo "${2}_restore_$3"
}
# Backup and restore IDs are 1 to 12 lowercase letters or digits.
B="${RUN: -8}"

# --- 1. the old server, its app databases, the probes and the seeded rows ---
if step_on 1; then
  kubectl -n "$NS" get statefulset upg-17 >/dev/null 2>&1 \
    || n db create postgres upg-17 -n "$NS" --version 17 --size 1Gi --recovery-backup postgres-backup --recovery-key-version v1 | tail -1
  ready upg-17
  expect "upg-17 runs PostgreSQL 17" "$(kubectl -n "$NS" exec upg-17-0 -- sh -c 'psql -U "$POSTGRES_USER" -d postgres -tAc "SHOW server_version_num"' | cut -c1-2)" "17"
  plan_stage old
  bind_probe ua-probe ua-pg ua-probe-old
  bind_probe ub-probe ub-pg ub-probe-old
  for a in ua ub; do
    pg_as upg-17 "$a-pg" "$a" "CREATE TABLE IF NOT EXISTS t(id serial PRIMARY KEY, v text NOT NULL)" >/dev/null
    drill_once "seed-$a" pg_rt "$a-probe" "INSERT INTO t(v) SELECT '$a-' || g FROM generate_series(1, 200) g"
  done
  log "1: upg-17 at 17 with ua-pg and ub-pg, each probe bound, 200 rows each written by the runtime users"
fi
fp_ua_old="$(drill_kept fp-ua-old pg_as upg-17 ua-pg ua "$FP")"
fp_ub_old="$(drill_kept fp-ub-old pg_as upg-17 ub-pg ub "$FP")"

# --- 2. a fresh backup of each, restored in isolation, equal to its source ---
if step_on 2; then
  for a in ua ub; do
    scratch="$(backup_restore "$a-pg" "$a" "pre$B")"
    expect "2: $a-pg's pre-upgrade backup restores equal" "$(pg_as upg-17 "$a-pg" "$scratch" "$FP")" "$(pg_as upg-17 "$a-pg" "$a" "$FP")"
  done
  log "2: fresh backups of ua-pg and ub-pg, ingested and restored into scratch, equal to their sources"
fi

# --- 3. the new server and the new app databases beside the old ---
if step_on 3; then
  kubectl -n "$NS" get statefulset upg-18 >/dev/null 2>&1 \
    || n db create postgres upg-18 -n "$NS" --version 18 --size 1Gi --recovery-backup postgres-backup --recovery-key-version v1 | tail -1
  ready upg-18
  expect "upg-18 runs PostgreSQL 18" "$(kubectl -n "$NS" exec upg-18-0 -- sh -c 'psql -U "$POSTGRES_USER" -d postgres -tAc "SHOW server_version_num"' | cut -c1-2)" "18"
  plan_stage both
  expect "3: ua-pg still serves its probe" "$(pg_rt ua-probe 'SELECT count(*) FROM t')" "${fp_ua_old%%:*}"
  # F86: the old server's in-place move to 18 is refused at planning.
  if out="$(N db create postgres upg-17 -n "$NS" --version 18 --size 1Gi --recovery-backup postgres-backup --recovery-key-version v1 --save-plan "$REVIEWS/in-place-$RUN" 2>&1)"; then
    fail "3: an in-place major change of upg-17 was planned"
  fi
  grep -q 'cannot open data files of another major version' <<<"$out" || { echo "$out" >&2; fail "3: the in-place refusal does not name the major version"; }
  log "3: upg-18 at 18 with ua-pg-v2 and ub-pg-v2 beside the old ones; an in-place 17 -> 18 is refused (F86)"
fi

# --- 4. ua: fence, copy, verify, switch ---
if step_on 4; then
  quiesce ua-pg fence
  refused "4: quiesced ua-pg runtime write" pg_rt ua-probe "INSERT INTO t(v) VALUES ('late')"
  expect "4: ua-pg unchanged while fenced" "$(pg_as upg-17 ua-pg ua "$FP")" "$fp_ua_old"
  [ "$(pg_as upg-18 ua-pg-v2 ua 'SELECT count(*) FROM pg_tables WHERE tablename = $$t$$')" = 1 ] || drill_once copy-ua copy ua-pg ua-pg-v2 ua ""
  expect "4: ua-pg-v2 equals ua-pg" "$(pg_as upg-18 ua-pg-v2 ua "$FP")" "$fp_ua_old"
  bind_probe ua-probe ua-pg-v2 ua-probe-v2
  drill_once write-ua-v2 pg_rt ua-probe "INSERT INTO t(v) VALUES ('ua-after-switch')"
  expect "4: the runtime write landed on 18" "$(pg_as upg-18 ua-pg-v2 ua "SELECT count(*) FROM t WHERE v = 'ua-after-switch'")" "1"
  expect "4: the probe reads PostgreSQL 18" "$(pg_rt ua-probe 'SHOW server_version_num' | cut -c1-2)" "18"
  expect "4: ua-pg kept every row and took no write" "$(pg_as upg-17 ua-pg ua "$FP")" "$fp_ua_old"
  log "4: ua-pg fenced, copied into ua-pg-v2 with equal fingerprints, ua-probe switched by review and writing to 18"
fi

# --- 5. ua-pg-v2 proven by its own backup before ua-pg retires ---
if step_on 5; then
  scratch="$(backup_restore ua-pg-v2 ua "pst$B")"
  expect "5: ua-pg-v2's backup restores equal" "$(pg_as upg-18 ua-pg-v2 "$scratch" "$FP")" "$(pg_as upg-18 ua-pg-v2 ua "$FP")"
  n db app-database retire ua-pg -n "$NS" --save-plan "$REVIEWS/retire-ua-pg" >/dev/null
  apply "$REVIEWS/retire-ua-pg"
  plan_stage final
  expect "5: retired ua-pg's data is kept" "$(kubectl -n "$NS" exec upg-17-0 -- sh -c 'psql -U "$POSTGRES_USER" -d ua -tAc "SELECT count(*) FROM t"')" "${fp_ua_old%%:*}"
  expect "5: retired ua-pg's schedule is suspended" "$(kubectl -n "$NS" get cronjob nagare-appdb-ua-pg -o jsonpath='{.spec.suspend}')" "true"
  log "5: ua-pg-v2's backup restored equal; only then ua-pg retired, its data kept and its schedule suspended"
fi

# --- 6. fail 1: the copy fails, and ub-pg takes writes again ---
if step_on 6; then
  quiesce ub-pg fail1
  # A failed copy leaves nothing, so a rerun repeats it.
  if copy ub-pg ub-pg-v2 ub "SELECT 1/0;" >> "$DRILL_RUN_DIR/copy-ub-fail.log" 2>&1; then fail "6: the injected copy failure did not fail"; fi
  expect "6: ub-pg-v2 holds nothing of the failed copy" "$(pg_as upg-18 ub-pg-v2 ub 'SELECT count(*) FROM pg_tables WHERE tablename = $$t$$')" "0"
  resume ub-pg fail1
  drill_once write-ub-fail1 pg_rt ub-probe "INSERT INTO t(v) VALUES ('ub-after-fail1')"
  expect "6: every acknowledged ub row is on ub-pg" "$(pg_as upg-17 ub-pg ub 'SELECT count(*) FROM t')" "$(( ${fp_ub_old%%:*} + 1 ))"
  log "6: fail 1: the copy failed in one transaction, ub-pg-v2 stayed empty, ub-pg resumed and took a write; nothing lost"
fi
fp_ub_fail1="$(drill_kept fp-ub-fail1 pg_as upg-17 ub-pg ub "$FP")"

# --- 7. fail 2: switched, rejected, and back to the old instance ---
if step_on 7; then
  quiesce ub-pg fail2
  [ "$(pg_as upg-18 ub-pg-v2 ub 'SELECT count(*) FROM pg_tables WHERE tablename = $$t$$')" = 1 ] || drill_once copy-ub copy ub-pg ub-pg-v2 ub ""
  expect "7: ub-pg-v2 equals ub-pg" "$(pg_as upg-18 ub-pg-v2 ub "$FP")" "$fp_ub_fail1"
  bind_probe ub-probe ub-pg-v2 ub-probe-v2
  # Rejected: the switch back is a reviewed deploy of the old binding, then the resume.
  bind_probe ub-probe ub-pg ub-probe-back
  resume ub-pg fail2
  drill_once write-ub-fail2 pg_rt ub-probe "INSERT INTO t(v) VALUES ('ub-after-fail2')"
  expect "7: ub-pg holds every acknowledged row" "$(pg_as upg-17 ub-pg ub 'SELECT count(*) FROM t')" "$(( ${fp_ub_old%%:*} + 2 ))"
  expect "7: ub-pg-v2 took no write" "$(pg_as upg-18 ub-pg-v2 ub "$FP")" "$fp_ub_fail1"
  log "7: fail 2: ub switched to 18 and rejected; a reviewed deploy of the old binding and a resume returned to ub-pg with every row"
fi

log "PASS"
drill_passed
