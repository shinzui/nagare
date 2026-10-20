#!/usr/bin/env bash
# scripts/local-app-database-smoke.sh (EP-202 M7) — app databases on shared servers, natively.
#
# On a bootstrapped LOCAL context (mode=local, a k3d cluster), with the packaged nagarectl:
#   1. servers smoke-pg and smoke-ch;
#   2. app databases alpha-pg, alpha-ch, beta-pg and beta-ch, planned and applied;
#   3. a re-plan has no operations;
#   4. four probe Workers, each binding one app database, on the servers' own images;
#   5. own-database read and write, and every cross-app denial;
#   5a. EP-205: quiesce alpha on both engines while beta's long queries run, back it up on
#      demand, ingest and restore it, resume it, and print the evidence; servers not restarted;
#   5b. EP-204: reviewed exceptions and ceilings on alpha-ch and a connection limit and
#      pg_monitor on alpha-pg hold, beta is unaffected, and removing an exception revokes it;
#   5c. EP-206: a reader on each alpha, declared since step 2, reads only its views under its
#      ceilings from a consumer probe; a non-consumer is refused; alpha-pg's reader rotates;
#   6. rotate alpha-pg's runtime user and retire beta-ch, the other apps unchanged;
#   7. one scheduled backup run of alpha-pg and alpha-ch, ingested and restored into scratch,
#      which no reader reaches; then alpha-pg's reader is retired (EP-206);
#   8. server status grades all four app databases' recovery points (beta-ch retired), and a
#      prune review of alpha-pg has no runs past policy (EP-203);
#   8a. EP-207: a run of a fresh app database taken before a logical database is added
#      ingests, restores only the databases it holds, and does not block a prune review;
#   9. app-database smoke: PASS.
#
# Usage (from an empty environment; the context names the cluster, never the ambient shell):
#   NAGARE_SMOKE_CONTEXT=NAME [NAGARECTL=/path/to/nagarectl] scripts/local-app-database-smoke.sh
# The context's kubeconfig is $XDG_CONFIG_HOME/nagare/kubeconfigs/NAME.yaml. Reviews, the probe
# configs and the image archives live under NAGARE_SMOKE_ROOT (default
# $XDG_STATE_HOME/nagare/app-database-smoke/NAME), so a rerun reuses the publications.
set -euo pipefail

CTX="${NAGARE_SMOKE_CONTEXT:?name a mode=local context in NAGARE_SMOKE_CONTEXT}"
NAGARECTL="${NAGARECTL:-$(command -v nagarectl)}"
NS=personal
ROOT="${NAGARE_SMOKE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/nagare/app-database-smoke/$CTX}"
RUN="s$(date -u +%m%d%H%M%S)"
REVIEWS="$ROOT/runs/$RUN"
mkdir -p "$REVIEWS" "$ROOT/config" "$ROOT/images"

log() { printf '%s app-database smoke: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "app-database smoke: FAIL: $*" >&2; exit 1; }
n() { "$NAGARECTL" --context "$CTX" "$@"; }
apply() { n inventory apply "$1" --yes > "$1.apply.log" 2>&1 || { tail -5 "$1.apply.log" >&2; fail "apply $1"; }; }

# --- 0. the context is local and its kubeconfig reaches a loopback cluster ---
ctx_env="$(n context env)"
grep -Eqx "export NAGARE_MODE='?local'?" <<<"$ctx_env" || fail "context $CTX is not mode=local"
eval "$(grep -E '^export (NAGARE_REGISTRY_HOST|NAGARE_ARTIFACT_REGISTRY_ID|CLOUDSDK_CORE_PROJECT)=' <<<"$ctx_env")"
export KUBECONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/nagare/kubeconfigs/$CTX.yaml"
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
case "$server" in https://127.0.0.1:*|https://0.0.0.0:*|https://localhost:*) ;; *) fail "kubeconfig server $server is not loopback" ;; esac
# Port 5000 on macOS belongs to AirPlay; host-side publications use the registry forward.
export NAGARE_LOCAL_REGISTRY_FORWARD="${NAGARE_LOCAL_REGISTRY_FORWARD:-127.0.0.1:15213}"
log "context $CTX ($server), nagarectl $("$NAGARECTL" version | head -1), reviews $REVIEWS"

secret() { kubectl -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" | base64 -d; }
digest_of() { kubectl -n "$NS" get secret "$1" -o jsonpath='{.data}' | sha256sum | cut -d' ' -f1; }

# --- 1. the shared servers ---
for pair in postgres:smoke-pg clickhouse:smoke-ch; do
  engine="${pair%%:*}"; name="${pair#*:}"
  if ! kubectl -n "$NS" get statefulset "$name" >/dev/null 2>&1; then
    n db create "$engine" "$name" -n "$NS" --recovery-backup "$engine-backup" --recovery-key-version v1 | tail -1
  fi
done
kubectl -n "$NS" rollout status statefulset/smoke-pg --timeout=300s >/dev/null
kubectl -n "$NS" rollout status statefulset/smoke-ch --timeout=300s >/dev/null
CH_ADMIN="$(secret nagare-db-smoke-ch CLICKHOUSE_USER)"; CH_ADMIN_PW="$(secret nagare-db-smoke-ch CLICKHOUSE_PASSWORD)"
for _ in $(seq 1 60); do
  kubectl -n "$NS" exec smoke-pg-0 -- pg_isready -h 127.0.0.1 >/dev/null 2>&1 \
    && kubectl -n "$NS" exec smoke-ch-0 -- clickhouse-client --user "$CH_ADMIN" --password "$CH_ADMIN_PW" --query 'SELECT 1' >/dev/null 2>&1 && break
  sleep 2
done
log "servers smoke-pg and smoke-ch are ready"

# --- 2. the app databases ---
# One config per stage of reviewed access (EP-204): none, declared, and declared with one
# exception removed. The later steps run with the last of them in force.
appdb_config() { # file, stage
  cat > "$1" <<EOF
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Lens ((&), (.~), (?~))
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Nagare.Dsl.AppDatabase
import Nagare.Dsl.Config (emitAppDatabases)
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Types (mkAppDatabaseName, mkDatabaseName, mkNamespace, mkReaderName, mkServiceName)

ok :: Either Text a -> a
ok = either (error . show) id

stage :: Text
stage = "$2"

app :: Text -> Text -> Engine -> [Text] -> AppDatabaseAccess -> AppDatabase
app name server engine (db : dbs) access' =
  AppDatabase
    { name = ok (mkAppDatabaseName name)
    , logicalKey = Nothing
    , server = ok (mkDatabaseName server)
    , engine = engine
    , namespace = ok (mkNamespace "personal")
    , logicalDatabases = ok (mapM mkLogicalDatabaseName (db :| dbs))
    , access = access'
    }
app _ _ _ [] _ = error "an app database needs a logical database"

ceilings :: Int -> Int -> Int -> UserLimits
ceilings memory seconds queries = noUserLimits & #maxMemoryBytes ?~ memory & #maxExecutionSeconds ?~ seconds & #maxConcurrentQueries ?~ queries

-- EP-206: one reader per engine in every stage, so a rerun never drops one.
dash :: Engine -> Text -> [Text] -> AppDatabaseReader
dash engine consumer (o : os) =
  AppDatabaseReader
    { name = ok (mkReaderName "dash")
    , objects = fmap (\rel -> ReaderRelation (ok (mkLogicalDatabaseName "alpha")) Nothing (ok (mkRelationName rel))) (o :| os)
    , limits = defaultReaderLimits engine
    , consumers = [ok (mkServiceName consumer)]
    , retired = stage == "retired" && engine == Postgres
    }
dash _ _ [] = error "a reader reads an object"

alphaCh, alphaPg, chAccess, pgAccess :: AppDatabaseAccess
alphaCh = chAccess & #readers .~ [dash ClickHouse "gamma-ch-probe" ["rv", "rpv"]]
alphaPg = pgAccess & #readers .~ [dash Postgres "gamma-pg-probe" ["rv"]]
chAccess
  | stage == "none" = noAppDatabaseAccess
  | otherwise =
      noAppDatabaseAccess
        & #runtime .~ UserAccess ([SystemParts] <> [SystemStoragePolicies | stage == "declared"] <> [ArbitraryTemporaryTables]) (ceilings 268435456 5 2)
        & #migration .~ UserAccess [] (ceilings 4294967296 600 4)
pgAccess
  | stage == "none" = noAppDatabaseAccess
  | otherwise =
      noAppDatabaseAccess
        & #monitoring .~ [PgMonitor]
        & #runtime . #limits .~ (noUserLimits & #connectionLimit ?~ 3 & #statementTimeoutSeconds ?~ 30)

main :: IO ()
main =
  emitAppDatabases
    [ app "alpha-pg" "smoke-pg" Postgres ["alpha"] alphaPg
    , app "beta-pg" "smoke-pg" Postgres ["beta"] noAppDatabaseAccess
    , app "alpha-ch" "smoke-ch" ClickHouse ["alpha", "alpha_ledger"] alphaCh
    , app "beta-ch" "smoke-ch" ClickHouse ["beta"] noAppDatabaseAccess
    ]
EOF
}
appdb_config "$ROOT/config/AppDatabases.hs" none
appdb_config "$ROOT/config/AppDatabasesDeclared.hs" declared
appdb_config "$ROOT/config/AppDatabasesRemoved.hs" removed
appdb_config "$ROOT/config/AppDatabasesRetired.hs" retired
# A rerun starts with every app database open: an interrupted earlier run may have left one quiesced.
for app in $(n db app-database list -n "$NS" 2>/dev/null | awk -F'\t' '$6 == "quiesced" {print $1}'); do
  n db app-database resume "$app" -n "$NS" --save-plan "$REVIEWS/rerun-resume-$app" >/dev/null
  apply "$REVIEWS/rerun-resume-$app"
done
# A rerun starts from no reviewed access: PGMQ's grants an earlier run left would be drift.
if kubectl -n "$NS" get secret alpha-pg-migration >/dev/null 2>&1; then
  kubectl -n "$NS" exec smoke-pg-0 -- env PGPASSWORD="$(secret alpha-pg-migration POSTGRES_PASSWORD)" \
    psql -h smoke-pg -U "$(secret alpha-pg-migration POSTGRES_USER)" -d alpha -v ON_ERROR_STOP=1 -tAc 'DROP SCHEMA IF EXISTS pgmq CASCADE' >/dev/null
  # ... and from alpha-pg's reader view and definer function absent (EP-206).
  kubectl -n "$NS" exec smoke-pg-0 -- env PGPASSWORD="$(secret alpha-pg-migration POSTGRES_PASSWORD)" \
    psql -h smoke-pg -U "$(secret alpha-pg-migration POSTGRES_USER)" -d alpha -v ON_ERROR_STOP=1 -tAc 'DROP VIEW IF EXISTS rv; DROP FUNCTION IF EXISTS add_row(integer)' >/dev/null
fi
if ! n db app-database plan --config "$ROOT/config/AppDatabases.hs" | grep -qx 'no operations'; then
  n db app-database plan --config "$ROOT/config/AppDatabases.hs" --save-plan "$REVIEWS/app-databases"
  apply "$REVIEWS/app-databases"
fi

# --- 3. converged ---
replan="$(n db app-database plan --config "$ROOT/config/AppDatabases.hs" 2>"$REVIEWS/replan.notes")"
grep -qx 'no operations' <<<"$replan" || { echo "$replan" >&2; fail "the re-plan has operations"; }
log "AC-1/AC-4: four app databases on one server per engine; re-plan: no operations"
# IR-33 AC-5: alpha-pg's reader is declared before the app creates its view.
grep -q 'pending: public.rv' "$REVIEWS/replan.notes" || { cat "$REVIEWS/replan.notes" >&2; fail "IR-33 AC-5: the plan names no pending view for alpha-pg's reader"; }
log "IR-33 AC-5: alpha-pg's reader converged with its view pending; no operation planned for it"
[ "$(kubectl -n "$NS" get statefulset -o name | grep -c 'smoke-')" = 2 ] || fail "expected exactly the two server StatefulSets"

# --- 4. probe Workers on the servers' own images, published through review ---
publish() { # local image, repository; prints the accepted image resource
  local image="$1" repo="$2" digest key archive out
  digest="$(docker image inspect "$image" --format '{{.Id}}' | cut -d: -f2)"
  key="${repo}-${digest:0:12}"
  archive="$ROOT/images/$key.tar"
  [ -s "$archive" ] || docker save "$image" -o "$archive"
  out="$(n app image-plan --archive "$archive" \
    --destination "${NAGARE_REGISTRY_HOST}/${CLOUDSDK_CORE_PROJECT}/${NAGARE_ARTIFACT_REGISTRY_ID}/${repo}:${digest:0:12}" \
    --key "$key" --save-plan "$REVIEWS/image-$repo")"
  apply "$REVIEWS/image-$repo" >&2
  printf '%s\n' "$out" | sed -n 's/^Image resource: //p' | tail -1
}
docker image inspect postgres:18 >/dev/null 2>&1 || docker pull postgres:18 >/dev/null
docker image inspect clickhouse/clickhouse-server:26.8 >/dev/null 2>&1 || docker pull clickhouse/clickhouse-server:26.8 >/dev/null
PG_IMAGE="$(publish postgres:18 appdb-probe-pg)"
CH_IMAGE="$(publish clickhouse/clickhouse-server:26.8 appdb-probe-ch)"
[ -n "$PG_IMAGE" ] && [ -n "$CH_IMAGE" ] || fail "an image review named no resource"

# beta-ch's probe is retired in step 6, and a retired Worker is not redeployed under its name,
# so each run gives it a fresh one.
probe_of() { if [ "$1" = beta-ch ]; then echo "beta-ch-$RUN"; else echo "$1-probe"; fi; }
tag_of() { docker image inspect "$1" --format '{{.Id}}' | cut -d: -f2 | cut -c1-12; }
probe() { # worker, app database, image resource, published repository, published tag
  mkdir -p "$ROOT/config/$1"
  cat > "$ROOT/config/$1/Config.hs" <<EOF
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Nagare.Dsl.Build (BuildSpec (PrebuiltImage), mkTag)
import Nagare.Dsl.Config (emitWorker)
import Nagare.Dsl.Types (mkAppDatabaseName)
import Nagare.Dsl.Worker (mkCommand, webWorker)

main :: IO ()
main = either (ioError . userError) emitWorker \$ do
  base <- webWorker "$1" "$4"
  tag <- first show (mkTag "$5")
  cmd <- first show (mkCommand ["sleep", "infinity"])
  appdb <- first show (mkAppDatabaseName "$2")
  Right (base & #build .~ PrebuiltImage tag & #command .~ Just cmd & #appDatabases .~ [appdb])
EOF
  n worker deploy -f "$ROOT/config/$1/Config.hs" --tag probe --image-resource "$3" --save-plan "$REVIEWS/worker-$1" >/dev/null
  apply "$REVIEWS/worker-$1"
}
PG_TAG="$(tag_of postgres:18)"; CH_TAG="$(tag_of clickhouse/clickhouse-server:26.8)"
probe alpha-pg-probe alpha-pg "$PG_IMAGE" appdb-probe-pg "$PG_TAG"
probe beta-pg-probe beta-pg "$PG_IMAGE" appdb-probe-pg "$PG_TAG"
probe alpha-ch-probe alpha-ch "$CH_IMAGE" appdb-probe-ch "$CH_TAG"
probe "$(probe_of beta-ch)" beta-ch "$CH_IMAGE" appdb-probe-ch "$CH_TAG"
for w in alpha-pg beta-pg alpha-ch beta-ch; do
  kubectl -n "$NS" rollout status "deployment/$(probe_of "$w")" --timeout=300s >/dev/null
done

# AC-2: each probe carries only its own app database's runtime Secret.
for w in alpha-pg beta-pg alpha-ch beta-ch; do
  refs="$(kubectl -n "$NS" get deployment "$(probe_of "$w")" -o json | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
refs = set()
for c in d["spec"]["template"]["spec"]["containers"]:
    for e in c.get("env", []):
        ref = (e.get("valueFrom") or {}).get("secretKeyRef")
        if ref: refs.add(ref["name"])
    for f in c.get("envFrom", []):
        if f.get("secretRef"): refs.add(f["secretRef"]["name"])
# Every workload carries its own optional user Secret; it holds no database credential.
refs.discard("nagare-secret-" + sys.argv[1] + "-runtime")
print(" ".join(sorted(refs)))' "$(probe_of "$w")")"
  [ "$refs" = "$w-runtime" ] || fail "probe $(probe_of "$w") references Secrets [$refs], not only $w-runtime"
done
log "AC-2: each probe references only its own <appdb>-runtime Secret"

# --- 5. own-database access and every cross-app denial ---
in_probe() { kubectl -n "$NS" exec "deployment/$(probe_of "$1")" -- sh -c "$2" sh "${@:3}"; }
pg_rt() { in_probe "$1" 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "${2:-$POSTGRES_DB}" -v ON_ERROR_STOP=1 -tAc "$1"' "$2" "${3:-}"; }
ch_rt() { in_probe "$1" 'clickhouse-client --host "$CLICKHOUSE_HOST" --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --database "$CLICKHOUSE_DB" --query "$1"' "$2"; }
# PostgreSQL migration users connect through the Service: the image's pg_hba trusts loopback.
pg_as() { kubectl -n "$NS" exec smoke-pg-0 -- env PGPASSWORD="$(secret "$1" POSTGRES_PASSWORD)" psql -h smoke-pg -U "$(secret "$1" POSTGRES_USER)" -d "$2" -v ON_ERROR_STOP=1 -tAc "$3"; }
# ClickHouse checks the password on every connection, loopback included.
ch_as() { kubectl -n "$NS" exec smoke-ch-0 -- clickhouse-client --user "$(secret "$1" CLICKHOUSE_USER)" --password "$(secret "$1" CLICKHOUSE_PASSWORD)" --query "$2"; }
ch_admin() { kubectl -n "$NS" exec smoke-ch-0 -- clickhouse-client --user "$CH_ADMIN" --password "$CH_ADMIN_PW" --query "$1"; }
refused() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then fail "AC-3: $label was allowed"; fi; }
expect() { [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"; }

for app in alpha beta; do
  pg_as "$app-pg-migration" "$app" "CREATE TABLE IF NOT EXISTS t(v text); TRUNCATE t;" >/dev/null
  pg_rt "$app-pg" "INSERT INTO t VALUES ('$app')" >/dev/null
  expect "$app-pg own read" "$(pg_rt "$app-pg" "SELECT string_agg(v, '|') FROM t")" "$app"
done
ch_as alpha-ch-migration "CREATE TABLE IF NOT EXISTS alpha.t (v String) ENGINE = MergeTree ORDER BY v"
ch_as alpha-ch-migration "CREATE TABLE IF NOT EXISTS alpha_ledger.l (v String) ENGINE = MergeTree ORDER BY v"
ch_as beta-ch-migration "CREATE TABLE IF NOT EXISTS beta.t (v String) ENGINE = MergeTree ORDER BY v"
for app in alpha beta; do
  ch_as "$app-ch-migration" "TRUNCATE TABLE $app.t"
  ch_rt "$app-ch" "INSERT INTO $app.t VALUES ('$app')"
  expect "$app-ch own read" "$(ch_rt "$app-ch" "SELECT groupArray(v)[1] FROM $app.t")" "$app"
done
ch_as alpha-ch-migration "TRUNCATE TABLE alpha_ledger.l"
ch_rt alpha-ch "INSERT INTO alpha_ledger.l VALUES ('ledger')"

PG_INITIAL="$(secret nagare-db-smoke-pg POSTGRES_DB)"
refused "alpha-pg runtime on beta" pg_rt alpha-pg 'SELECT 1' beta
refused "beta-pg runtime on alpha" pg_rt beta-pg 'SELECT 1' alpha
refused "alpha-pg runtime on the server's database" pg_rt alpha-pg 'SELECT 1' "$PG_INITIAL"
refused "alpha-pg migration on beta" pg_as alpha-pg-migration beta 'SELECT 1'
refused "alpha-pg runtime DDL" pg_rt alpha-pg 'CREATE TABLE ddl(v text)'
refused "alpha-ch runtime on beta" ch_rt alpha-ch 'SELECT count() FROM beta.t'
refused "beta-ch runtime on alpha" ch_rt beta-ch 'SELECT count() FROM alpha.t'
refused "beta-ch runtime on alpha_ledger" ch_rt beta-ch 'SELECT count() FROM alpha_ledger.l'
refused "alpha-ch migration on beta" ch_as alpha-ch-migration 'SELECT count() FROM beta.t'
refused "alpha-ch runtime DDL" ch_rt alpha-ch 'CREATE TABLE alpha.ddl (v String) ENGINE = MergeTree ORDER BY v'
refused "alpha-ch runtime insert into beta" ch_rt alpha-ch "INSERT INTO beta.t VALUES ('intruder')"
refused "alpha-ch migration DDL on beta" ch_as alpha-ch-migration 'CREATE TABLE beta.ddl (v String) ENGINE = MergeTree ORDER BY v'
refused "alpha-ch runtime creates a user" ch_rt alpha-ch 'CREATE USER smoke_intruder'
refused "alpha-ch runtime grants" ch_rt alpha-ch 'GRANT SELECT ON alpha.* TO default'
refused "alpha-ch runtime controls the server" ch_rt alpha-ch 'SYSTEM RELOAD CONFIG'
refused "alpha-pg runtime creates a role" pg_rt alpha-pg 'CREATE ROLE smoke_intruder'
refused "alpha-pg runtime grants a role" pg_rt alpha-pg 'GRANT pg_read_all_data TO CURRENT_USER'
refused "alpha-pg runtime controls the server" pg_rt alpha-pg 'SELECT pg_reload_conf()'
log "AC-3: own read and write for all four; eighteen cross-app, DDL and control denials hold"

# --- 5a. EP-205: a maintenance window on alpha, beta untouched, servers not restarted ---
pg_admin() { kubectl -n "$NS" exec smoke-pg-0 -- sh -c 'psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -tAc "$1"' sh "$1"; }
pod_identity() { kubectl -n "$NS" get pod "$1" -o jsonpath='{.metadata.uid} {.status.startTime}'; }
spec_of() { kubectl -n "$NS" get cronjob "$1" -o json | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["spec"], sort_keys=True))'; }
CH_MIG_USER="$(secret alpha-ch-migration CLICKHOUSE_USER)"
CH_RT_USER="$(secret alpha-ch-runtime CLICKHOUSE_USER)"
PG_RT_USER="$(secret alpha-pg-runtime POSTGRES_USER)"
ch_as alpha-ch-migration "CREATE TABLE IF NOT EXISTS alpha.src (k UInt64) ENGINE = MergeTree ORDER BY k"
ch_as alpha-ch-migration "CREATE TABLE IF NOT EXISTS alpha.agg (n UInt64) ENGINE = SummingMergeTree ORDER BY tuple()"
ch_as alpha-ch-migration "CREATE MATERIALIZED VIEW IF NOT EXISTS alpha.mv TO alpha.agg DEFINER = $CH_MIG_USER SQL SECURITY DEFINER AS SELECT count() AS n FROM alpha.src"
ch_as alpha-ch-migration "CREATE VIEW IF NOT EXISTS alpha.dv DEFINER = $CH_MIG_USER SQL SECURITY DEFINER AS SELECT count() AS c FROM alpha.t"
# The app's own databases and server-wide grants; the window's scratch restore adds its own.
grants_q="SELECT user_name, access_type, database, table, column, is_partial_revoke, grant_option FROM system.grants WHERE user_name IN ('$CH_RT_USER', '$CH_MIG_USER') AND (database IS NULL OR database IN ('alpha', 'alpha_ledger', 'system')) ORDER BY ALL FORMAT TSV"
grants_before="$(ch_admin "$grants_q" | sha256sum)"
ch_pod="$(pod_identity smoke-ch-0)"; pg_pod="$(pod_identity smoke-pg-0)"; ch_uuid="$(ch_admin 'SELECT serverUUID()')"
cron_ch="$(spec_of nagare-appdb-alpha-ch)"; cron_pg="$(spec_of nagare-appdb-alpha-pg)"
long_ch='SELECT sleepEachRow(1) FROM numbers(600) SETTINGS max_block_size = 1 FORMAT Null'
for app in alpha beta; do
  (ch_rt "$app-ch" "$long_ch" >/dev/null 2>&1 || true) &
  (pg_rt "$app-pg" 'SELECT pg_sleep(600)' >/dev/null 2>&1 || true) &
done
sleep 3
for app in alpha-ch alpha-pg; do
  n db app-database quiesce "$app" -n "$NS" --users runtime --save-plan "$REVIEWS/quiesce-$app" >/dev/null
  apply "$REVIEWS/quiesce-$app"
done
expect "IR-31 AC-1: alpha-ch runtime queries after the drain" "$(ch_admin "SELECT count() FROM system.processes WHERE user = '$CH_RT_USER'")" "0"
expect "IR-31 AC-1: alpha-pg runtime sessions after the drain" "$(pg_admin "SELECT count(*) FROM pg_stat_activity WHERE usename = '$PG_RT_USER'")" "0"
[ "$(ch_admin "SELECT count() FROM system.processes WHERE user = '$(secret beta-ch-runtime CLICKHOUSE_USER)'")" -ge 1 ] || fail "IR-31 AC-1: beta-ch's long query did not keep running"
[ "$(pg_admin "SELECT count(*) FROM pg_stat_activity WHERE usename = '$(secret beta-pg-runtime POSTGRES_USER)'")" -ge 1 ] || fail "IR-31 AC-1: beta-pg's long query did not keep running"
refused "quiesced alpha-ch runtime login" ch_as alpha-ch-runtime 'SELECT 1'
refused "quiesced alpha-pg runtime login" pg_rt alpha-pg 'SELECT 1'
expect "alpha-ch migration stays open" "$(ch_as alpha-ch-migration 'SELECT 1')" "1"
for app in alpha-ch alpha-pg; do
  expect "IR-31 AC-4: $app schedule suspended" "$(kubectl -n "$NS" get cronjob "nagare-appdb-$app" -o jsonpath='{.spec.suspend}')" "true"
done
expect "IR-31: alpha-ch server pod unchanged" "$(pod_identity smoke-ch-0)" "$ch_pod"
expect "IR-31: alpha-pg server pod unchanged" "$(pod_identity smoke-pg-0)" "$pg_pod"
expect "IR-31: ClickHouse server UUID unchanged" "$(ch_admin 'SELECT serverUUID()')" "$ch_uuid"
out="$(n db app-database plan --config "$ROOT/config/AppDatabases.hs")"
grep -q 'app database alpha-ch is quiesced; left out of this plan' <<<"$out" || { echo "$out" >&2; fail "IR-31: plan did not leave quiesced alpha-ch out"; }
if out="$(n db app-database rotate alpha-pg -n "$NS" --user runtime --save-plan "$REVIEWS/rotate-quiesced" 2>&1)"; then fail "IR-31: a quiesced app database's rotation was reviewed"; fi
grep -q 'app-database-quiesced' <<<"$out" || { echo "$out" >&2; fail "IR-31: rotation of a quiesced app database did not refuse with app-database-quiesced"; }
# IR-31 AC-5: an on-demand backup of each, quiesced, ingested and restored into scratch.
OD="q${RUN#s}"
for app in alpha-pg alpha-ch; do
  n db app-database backup "$app" -n "$NS" --backup-id "$OD" --save-plan "$REVIEWS/backup-$app" >/dev/null
  apply "$REVIEWS/backup-$app"
  job="nagare-appdb-$app-$OD"
  kubectl -n "$NS" wait --for=condition=complete "job/$job" --timeout=600s >/dev/null \
    || { kubectl -n "$NS" logs "job/$job" --all-containers --tail=20 >&2 || true; fail "on-demand backup $job did not complete"; }
  uid="$(kubectl -n "$NS" get job "$job" -o jsonpath='{.metadata.uid}')"
  n db app-database backup-receipts "$app" -n "$NS" --backup-id "$uid" --save-plan "$REVIEWS/ingest-od-$app" >/dev/null
  apply "$REVIEWS/ingest-od-$app"
  n db app-database restore "$app" -n "$NS" --backup-id "$uid" --restore-id "$OD" --save-plan "$REVIEWS/restore-od-$app" >/dev/null
  apply "$REVIEWS/restore-od-$app"
done
expect "IR-31 AC-5: alpha-pg on-demand scratch rows" "$(pg_as alpha-pg-migration "alpha_restore_$OD" "SELECT string_agg(v, '|') FROM t")" "alpha"
expect "IR-31 AC-5: alpha-ch on-demand scratch rows" "$(ch_as alpha-ch-migration "SELECT groupArray(v)[1] FROM alpha_restore_$OD.t")" "alpha"
for app in alpha-ch alpha-pg; do
  n db app-database resume "$app" -n "$NS" --save-plan "$REVIEWS/resume-$app" >/dev/null
  apply "$REVIEWS/resume-$app"
done
expect "IR-31 AC-4: alpha-ch schedule as accepted" "$(spec_of nagare-appdb-alpha-ch)" "$cron_ch"
expect "IR-31 AC-4: alpha-pg schedule as accepted" "$(spec_of nagare-appdb-alpha-pg)" "$cron_pg"
expect "IR-31 AC-2: alpha's grants after resume" "$(ch_admin "$grants_q" | sha256sum)" "$grants_before"
ch_as alpha-ch-migration "INSERT INTO alpha.src VALUES (1)"
[ "$(ch_rt alpha-ch 'SELECT c FROM alpha.dv')" -ge 1 ] || fail "IR-31 AC-2: alpha's definer view does not read after resume"
[ "$(ch_rt alpha-ch 'SELECT sum(n) FROM alpha.agg')" -ge 1 ] || fail "IR-31 AC-2: alpha's materialized view does not read after resume"
expect "alpha-pg reads after resume" "$(pg_rt alpha-pg "SELECT string_agg(v, '|') FROM t")" "alpha"
for app in alpha-ch alpha-pg; do
  evidence="$(n db app-database evidence "$app" -n "$NS" --json)"
  python3 -I - "$evidence" <<'PY' || { echo "$evidence" >&2; fail "IR-31 AC-6: $app evidence is incomplete"; }
import json, sys
e = json.loads(sys.argv[1])
for key in ("server", "serverAtResume", "blockedUsers", "drain", "backup", "resume"):
    assert e[key], key
assert e["sessionsObserved"] == 0 and e["activeRuns"] == 0 and e["unfinishedMutations"] == []
same = lambda i: {k: v for k, v in i.items() if k != "processStarted"}
assert same(e["server"]) == same(e["serverAtResume"]), (e["server"], e["serverAtResume"])
assert "podUID" in e["server"] and ("serverUUID" in e["server"] or "systemIdentifier" in e["server"])
assert e["backup"]["backupId"] and e["backup"]["receipt"]
PY
done
ch_admin "KILL QUERY WHERE user = '$(secret beta-ch-runtime CLICKHOUSE_USER)' SYNC FORMAT Null" >/dev/null
pg_admin "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = '$(secret beta-pg-runtime POSTGRES_USER)'" >/dev/null
wait
log "IR-31: alpha quiesced and drained on both engines while beta ran; on-demand backups ingested and restored; resumed with schedules as accepted; servers not restarted"

# --- 5b. EP-204: reviewed exceptions and limits ---
plan_out="$(n db app-database plan --config "$ROOT/config/AppDatabasesDeclared.hs" --save-plan "$REVIEWS/access-declared")"
for needle in "exceptions system-parts, system-storage-policies, arbitrary-temporary-tables" "maxMemoryBytes 268435456" "connectionLimit 3" "tolerates grants to pg_monitor"; do
  { grep -qF "$needle" <<<"$plan_out" || grep -rqF "$needle" "$REVIEWS/access-declared"; } || { echo "$plan_out" >&2; fail "IR-30 AC-1: the reviewed plan does not name '$needle'"; }
done
apply "$REVIEWS/access-declared"
replan="$(n db app-database plan --config "$ROOT/config/AppDatabasesDeclared.hs")"
grep -qx 'no operations' <<<"$replan" || { echo "$replan" >&2; fail "the re-plan with declared access has operations"; }
code_of() { grep -oE 'Code: [0-9]+' <<<"$1" | head -1; }
# IR-30 AC-2: the declared system tables, own rows only, and Join temporary tables; no source engine.
[ "$(ch_rt alpha-ch "SELECT count() FROM system.parts WHERE database = 'alpha'")" -gt 0 ] || fail "IR-30 AC-2: alpha-ch runtime sees no parts of its own tables"
expect "IR-30 AC-2: alpha-ch runtime sees beta's parts" "$(ch_rt alpha-ch "SELECT count() FROM system.parts WHERE database = 'beta'")" "0"
expect "IR-30 AC-2: alpha-ch runtime reads storage policies" "$(ch_rt alpha-ch "SELECT count() > 0 FROM system.storage_policies")" "1"
refused "undeclared system.mutations for alpha-ch runtime" ch_rt alpha-ch 'SELECT count() FROM system.mutations'
refused "undeclared system.parts for beta-ch runtime" ch_rt beta-ch 'SELECT count() FROM system.parts'
expect "IR-30 AC-2: alpha-ch runtime Join temporary table" "$(ch_rt alpha-ch "CREATE TEMPORARY TABLE j (k UInt64, v String) ENGINE = Join(ANY, LEFT, k); INSERT INTO j VALUES (1, 'x'); SELECT joinGet(j, 'v', toUInt64(1))")" "x"
out="$(ch_rt alpha-ch "CREATE TEMPORARY TABLE x (s String) ENGINE = URL('http://example.invalid/', CSV)" 2>&1 || true)"
expect "IR-30 AC-2: a URL temporary table" "$(code_of "$out")" "Code: 497"
# IR-32 AC-1: alpha's ceilings stop its probes; beta runs the same queries.
out="$(ch_rt alpha-ch 'SELECT sum(cityHash64(number)) FROM numbers(100000000000) SETTINGS max_threads = 1' 2>&1 || true)"
expect "IR-32 AC-1: alpha time ceiling" "$(code_of "$out")" "Code: 159"
out="$(ch_rt beta-ch 'SELECT sum(cityHash64(number)) FROM numbers(100000000000) SETTINGS max_threads = 1, max_execution_time = 7' 2>&1 || true)"
grep -qE 'elapsed 7[0-9]{3}\.[0-9]+ ms' <<<"$out" || { echo "$out" >&2; fail "IR-32 AC-1: beta's time probe was not stopped by its own 7 s cap"; }
out="$(ch_rt alpha-ch 'SELECT length(groupArray(number)) FROM numbers(30000000)' 2>&1 || true)"
expect "IR-32 AC-1: alpha memory ceiling" "$(code_of "$out")" "Code: 241"
expect "IR-32 AC-1: beta memory probe" "$(ch_rt beta-ch 'SELECT length(groupArray(number)) FROM numbers(30000000)')" "30000000"
concurrent() { # app database; prints how many of three concurrent sleep(3) were refused
  local outs="$REVIEWS/concurrent-$1" i
  mkdir -p "$outs"
  for i in 1 2 3; do (ch_rt "$1" 'SELECT sleep(3)' >"$outs/$i" 2>&1 || true) & sleep 0.5; done
  wait
  cat "$outs"/* | grep -c 'Code: 202' || true
}
expect "IR-32 AC-1: alpha concurrency ceiling refusals" "$(concurrent alpha-ch)" "1"
expect "IR-32 AC-1: beta concurrency refusals" "$(concurrent beta-ch)" "0"
# IR-32 AC-2: lower is accepted, higher and zero are refused, undeclared settings stay writable.
expect "IR-32 AC-2: a lower memory ceiling" "$(ch_rt alpha-ch 'SET max_memory_usage = 134217728; SELECT 1')" "1"
for setting in "max_memory_usage = 536870912" "max_memory_usage = 0" "max_execution_time = 0" "max_concurrent_queries_for_user = 0"; do
  out="$(ch_rt alpha-ch "SET $setting; SELECT 1" 2>&1 || true)"
  expect "IR-32 AC-2: SET $setting" "$(code_of "$out")" "Code: 452"
done
expect "IR-32 AC-2: an undeclared setting" "$(ch_rt alpha-ch 'SET enable_analyzer = 0; SELECT 1')" "1"
# IR-32 AC-3: the fourth connection of alpha-pg's runtime user is refused.
for i in 1 2 3; do (pg_rt alpha-pg 'SELECT pg_sleep(8)' >/dev/null 2>&1 || true) & done
sleep 4
out="$(pg_rt alpha-pg 'SELECT 1' 2>&1 || true)"
grep -q 'too many connections for role' <<<"$out" || { echo "$out" >&2; fail "IR-32 AC-3: a fourth alpha-pg runtime connection was not refused"; }
wait
expect "alpha-pg runtime statement_timeout default" "$(pg_rt alpha-pg 'SHOW statement_timeout')" "30s"
# IR-30 AC-4: PGMQ's install grants to pg_monitor, run by the migration user, are declared.
pg_as alpha-pg-migration alpha "CREATE SCHEMA pgmq; CREATE TABLE pgmq.meta (queue_name text PRIMARY KEY); CREATE SEQUENCE pgmq.s;
GRANT USAGE ON SCHEMA pgmq TO pg_monitor;
GRANT SELECT ON ALL TABLES IN SCHEMA pgmq TO pg_monitor;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA pgmq TO pg_monitor;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgmq GRANT SELECT ON TABLES TO pg_monitor;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgmq GRANT SELECT ON SEQUENCES TO pg_monitor;" >/dev/null
replan="$(n db app-database plan --config "$ROOT/config/AppDatabasesDeclared.hs")"
grep -qx 'no operations' <<<"$replan" || { echo "$replan" >&2; fail "IR-30 AC-4: PGMQ's grants to a declared pg_monitor re-plan with operations"; }
if out="$(n db app-database plan --config "$ROOT/config/AppDatabases.hs" 2>&1)"; then fail "IR-30 AC-4: undeclared pg_monitor grants planned"; fi
grep -q 'app-database-grant-drift.*pg_monitor' <<<"$out" || { echo "$out" >&2; fail "IR-30 AC-4: undeclared pg_monitor grants are not reported as drift"; }
# IR-30 AC-5: removing an exception revokes it through review.
plan_out="$(n db app-database plan --config "$ROOT/config/AppDatabasesRemoved.hs" --save-plan "$REVIEWS/access-removed")"
grep -q 'update app-database user alpha_ch_runtime on smoke-ch; exceptions system-parts, arbitrary-temporary-tables;' "$REVIEWS/access-removed/review.json" || { echo "$plan_out" >&2; fail "IR-30 AC-5: removing an exception planned no update of alpha_ch_runtime"; }
apply "$REVIEWS/access-removed"
refused "the removed system.storage_policies exception" ch_rt alpha-ch 'SELECT count() FROM system.storage_policies'
replan="$(n db app-database plan --config "$ROOT/config/AppDatabasesRemoved.hs")"
grep -qx 'no operations' <<<"$replan" || { echo "$replan" >&2; fail "the re-plan after the removal has operations"; }
log "EP-204: alpha-ch exceptions and ceilings hold, beta unaffected; alpha-pg connection limit and pg_monitor grants hold; removal revoked"

# --- 5c. EP-206: read-only readers ---
# The app's migrations create the views the readers declare.
pg_as alpha-pg-migration alpha "CREATE OR REPLACE VIEW rv AS SELECT v FROM t" >/dev/null
ch_as alpha-ch-migration "INSERT INTO alpha.src VALUES (1)"
ch_as alpha-ch-migration "CREATE VIEW IF NOT EXISTS alpha.rv DEFINER = $CH_MIG_USER SQL SECURITY DEFINER AS SELECT k FROM alpha.src"
ch_as alpha-ch-migration "CREATE VIEW IF NOT EXISTS alpha.rpv DEFINER = $CH_MIG_USER SQL SECURITY DEFINER AS SELECT k FROM alpha.src WHERE k = {x:UInt64}"
# IR-33 AC-5: the plan after the migration grants the view, then nothing is left.
plan_out="$(n db app-database plan --config "$ROOT/config/AppDatabasesRemoved.hs" --save-plan "$REVIEWS/readers" 2>&1)" || { echo "$plan_out" >&2; fail "IR-33 AC-5: plan after the migration"; }
grep -q 'update app-database user alpha_pg_reader_dash' "$REVIEWS/readers/review.json" || { echo "$plan_out" >&2; fail "IR-33 AC-5: the view created by the migration is not granted by review"; }
apply "$REVIEWS/readers"
replan="$(n db app-database plan --config "$ROOT/config/AppDatabasesRemoved.hs" 2>&1)"
{ grep -qx 'no operations' <<<"$replan" && ! grep -q pending <<<"$replan"; } || { echo "$replan" >&2; fail "IR-33 AC-5: the re-plan after the migration is not empty"; }
# IR-33 AC-9: a SECURITY DEFINER function PUBLIC may run refuses the plan until the app revokes it.
pg_as alpha-pg-migration alpha "CREATE FUNCTION add_row(x integer) RETURNS integer LANGUAGE sql SECURITY DEFINER AS 'SELECT 1'" >/dev/null
if out="$(n db app-database plan --config "$ROOT/config/AppDatabasesRemoved.hs" 2>&1)"; then fail "IR-33 AC-9: a definer function PUBLIC may run was planned"; fi
grep -q 'app-database-reader-definer-function.*add_row(x integer)' <<<"$out" || { echo "$out" >&2; fail "IR-33 AC-9: the definer refusal does not name add_row"; }
pg_as alpha-pg-migration alpha "REVOKE EXECUTE ON FUNCTION add_row(integer) FROM PUBLIC" >/dev/null
replan="$(n db app-database plan --config "$ROOT/config/AppDatabasesRemoved.hs" 2>/dev/null)"
grep -qx 'no operations' <<<"$replan" || { echo "$replan" >&2; fail "IR-33 AC-9: the plan after the app's revoke is not empty"; }
reader_probe() { # worker, app database whose reader it binds (or none), image resource, published repository, published tag
  mkdir -p "$ROOT/config/$1"
  local bound=""
  [ "$2" = none ] || bound="\"$2\""
  cat > "$ROOT/config/$1/Config.hs" <<EOF
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Nagare.Dsl.Build (BuildSpec (PrebuiltImage), mkTag)
import Nagare.Dsl.Config (emitWorker)
import Nagare.Dsl.Types (AppDatabaseReaderRef (..), mkAppDatabaseName, mkReaderName)
import Nagare.Dsl.Worker (mkCommand, webWorker)

main :: IO ()
main = either (ioError . userError) emitWorker \$ do
  base <- webWorker "$1" "$4"
  tag <- first show (mkTag "$5")
  cmd <- first show (mkCommand ["sleep", "infinity"])
  refs <- first show (sequence [AppDatabaseReaderRef <\$> mkAppDatabaseName db <*> mkReaderName "dash" | db <- [$bound]])
  Right (base & #build .~ PrebuiltImage tag & #command .~ Just cmd & #appDatabaseReaders .~ refs)
EOF
  n worker deploy -f "$ROOT/config/$1/Config.hs" --tag probe --image-resource "$3" --save-plan "$REVIEWS/worker-$1-$2" 2>&1
}
reader_probe gamma-pg-probe alpha-pg "$PG_IMAGE" appdb-probe-pg "$PG_TAG" >/dev/null || fail "IR-33 AC-6: plan gamma-pg-probe"
apply "$REVIEWS/worker-gamma-pg-probe-alpha-pg"
reader_probe gamma-ch-probe alpha-ch "$CH_IMAGE" appdb-probe-ch "$CH_TAG" >/dev/null || fail "IR-33 AC-6: plan gamma-ch-probe"
apply "$REVIEWS/worker-gamma-ch-probe-alpha-ch"
# IR-33 AC-6: a workload the reader does not list is refused.
if out="$(reader_probe delta-pg-probe alpha-pg "$PG_IMAGE" appdb-probe-pg "$PG_TAG")"; then fail "IR-33 AC-6: a non-consumer bound alpha-pg's reader"; fi
grep -q 'app-database-reader-not-a-consumer' <<<"$out" || { echo "$out" >&2; fail "IR-33 AC-6: the non-consumer refusal has the wrong code"; }
for w in gamma-pg gamma-ch; do kubectl -n "$NS" rollout status "deployment/$w-probe" --timeout=300s >/dev/null; done
secret_refs() { kubectl -n "$NS" get deployment "$1" -o json | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
refs = {(e.get("valueFrom") or {}).get("secretKeyRef", {}).get("name") for c in d["spec"]["template"]["spec"]["containers"] for e in c.get("env", [])}
refs.discard(None); refs.discard("nagare-secret-" + sys.argv[1] + "-runtime")
print(" ".join(sorted(refs)))' "$1"; }
expect "IR-33 AC-6: gamma-pg-probe's Secrets" "$(secret_refs gamma-pg-probe)" "alpha-pg-reader-dash"
expect "IR-33 AC-6: gamma-ch-probe's Secrets" "$(secret_refs gamma-ch-probe)" "alpha-ch-reader-dash"
# IR-33 AC-2/AC-3 on PostgreSQL: the declared view only; grants are the boundary, whatever the session sets.
expect "IR-33 AC-2: alpha-pg reader reads its view" "$(pg_rt gamma-pg "SELECT string_agg(v, '|') FROM rv")" "alpha"
refused "alpha-pg reader on the base table" pg_rt gamma-pg 'SELECT count(*) FROM t'
refused "alpha-pg reader INSERT with read-only off" pg_rt gamma-pg "SET default_transaction_read_only = off; INSERT INTO t VALUES ('x')"
refused "alpha-pg reader CREATE TABLE" pg_rt gamma-pg 'SET default_transaction_read_only = off; CREATE TABLE x (i int)'
refused "alpha-pg reader temporary table" pg_rt gamma-pg 'SET default_transaction_read_only = off; CREATE TEMPORARY TABLE x (i int)'
refused "alpha-pg reader on beta" pg_rt gamma-pg 'SELECT 1' beta
expect "alpha-pg reader statement_timeout default" "$(pg_rt gamma-pg 'SHOW statement_timeout')" "30s"
for i in 1 2 3 4 5; do (pg_rt gamma-pg 'SELECT pg_sleep(8)' >/dev/null 2>&1 || true) & done
sleep 4
out="$(pg_rt gamma-pg 'SELECT 1' 2>&1 || true)"
grep -q 'too many connections for role' <<<"$out" || { echo "$out" >&2; fail "IR-33 AC-3: a sixth alpha-pg reader connection was not refused"; }
wait
# IR-33 AC-2/AC-3 on ClickHouse: its definer views, nothing else, under CONST and MIN 1 MAX ceilings.
expect "IR-33 AC-2: alpha-ch reader reads its view" "$(ch_rt gamma-ch 'SELECT count() > 0 FROM alpha.rv')" "1"
expect "IR-33 AC-2: alpha-ch reader reads its parameterized view" "$(ch_rt gamma-ch 'SELECT count() FROM alpha.rpv(x = 1)')" "$(ch_admin 'SELECT count() FROM alpha.src WHERE k = 1')"
for q in 'SELECT count() FROM alpha.src' 'SELECT count() FROM alpha.t' 'SELECT count() FROM beta.t' 'INSERT INTO alpha.src VALUES (2)' 'CREATE TABLE alpha.x (k UInt64) ENGINE = Memory' 'SELECT count() FROM system.parts'; do
  out="$(ch_rt gamma-ch "$q" 2>&1 || true)"
  expect "IR-33 AC-2: alpha-ch reader: $q" "$(code_of "$out")" "Code: 497"
done
out="$(ch_rt gamma-ch 'SET readonly = 0; SELECT 1' 2>&1 || true)"
expect "IR-33 AC-3: alpha-ch reader SET readonly = 0" "$(code_of "$out")" "Code: 164"
for setting in "max_threads = 8" "max_result_rows = 0" "max_execution_time = 60" "max_memory_usage = 0" "max_result_bytes = 104857600"; do
  out="$(ch_rt gamma-ch "SET $setting; SELECT 1" 2>&1 || true)"
  expect "IR-33 AC-3: alpha-ch reader SET $setting" "$(code_of "$out")" "Code: 452"
done
# IR-33 AC-7: rotating alpha-pg's reader changes its Secret only; its consumer reads after a restart.
old_reader_pw="$(secret alpha-pg-reader-dash POSTGRES_PASSWORD)"; alpha_rt="$(digest_of alpha-pg-runtime)"
n db app-database rotate alpha-pg -n "$NS" --user reader-dash --save-plan "$REVIEWS/rotate-reader" >/dev/null
apply "$REVIEWS/rotate-reader"
[ "$(secret alpha-pg-reader-dash POSTGRES_PASSWORD)" != "$old_reader_pw" ] || fail "IR-33 AC-7: the reader rotation left its password unchanged"
expect "alpha-pg runtime Secret after the reader rotation" "$(digest_of alpha-pg-runtime)" "$alpha_rt"
selector="$(kubectl -n "$NS" get deployment gamma-pg-probe -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')"
kubectl -n "$NS" delete pod -l "${selector%,}" --wait=false >/dev/null
kubectl -n "$NS" rollout status deployment/gamma-pg-probe --timeout=300s >/dev/null
for _ in $(seq 1 30); do pg_rt gamma-pg 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done
expect "alpha-pg reader after its rotation" "$(pg_rt gamma-pg 'SELECT count(*) FROM rv')" "1"
log "IR-33: readers read only their views under their ceilings from consumer probes; a non-consumer was refused; a definer function refused until revoked; the reader rotated alone"

# --- 6. rotate alpha-pg's runtime user, retire beta-ch ---
old_pw="$(secret alpha-pg-runtime POSTGRES_PASSWORD)"; old_user="$(secret alpha-pg-runtime POSTGRES_USER)"
beta_pg="$(digest_of beta-pg-runtime)"; alpha_mig="$(digest_of alpha-pg-migration)"
n db app-database rotate alpha-pg -n "$NS" --user runtime --save-plan "$REVIEWS/rotate" >/dev/null
apply "$REVIEWS/rotate"
[ "$(secret alpha-pg-runtime POSTGRES_PASSWORD)" != "$old_pw" ] || fail "rotation left the runtime password unchanged"
expect "beta-pg Secret after rotation" "$(digest_of beta-pg-runtime)" "$beta_pg"
expect "alpha-pg migration Secret after rotation" "$(digest_of alpha-pg-migration)" "$alpha_mig"
refused "the rotated-out password" kubectl -n "$NS" exec smoke-pg-0 -- env PGPASSWORD="$old_pw" psql -h smoke-pg -U "$old_user" -d alpha -tAc 'SELECT 1'
# A rotation takes effect in a workload when its pods restart.
selector="$(kubectl -n "$NS" get deployment alpha-pg-probe -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')"
kubectl -n "$NS" delete pod -l "${selector%,}" --wait=false >/dev/null
kubectl -n "$NS" rollout status deployment/alpha-pg-probe --timeout=300s >/dev/null
for _ in $(seq 1 30); do pg_rt alpha-pg 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done
expect "alpha-pg read after rotation" "$(pg_rt alpha-pg "SELECT string_agg(v, '|') FROM t")" "alpha"
expect "beta-pg read after rotation" "$(pg_rt beta-pg "SELECT string_agg(v, '|') FROM t")" "beta"

# Retire this run's beta-ch probe and any an interrupted earlier run left behind.
for w in $(kubectl -n "$NS" get deployment -o name | sed -n 's|^deployment.apps/\(beta-ch-s[0-9]*\)$|\1|p'); do
  # A retired probe leaves accepted history while its Deployment is retained.
  if ! out="$(n worker delete "$w" -n "$NS" --save-plan "$REVIEWS/retire-$w" 2>&1)"; then
    grep -q 'has no unique worker Deployment' <<<"$out" && continue
    echo "$out" >&2; fail "worker delete $w"
  fi
  apply "$REVIEWS/retire-$w"
done
n db app-database retire beta-ch -n "$NS" --save-plan "$REVIEWS/retire-beta-ch" >/dev/null
apply "$REVIEWS/retire-beta-ch"
refused "retired beta-ch runtime login" ch_as beta-ch-runtime 'SELECT 1'
refused "retired beta-ch migration login" ch_as beta-ch-migration 'SELECT 1'
expect "beta-ch data kept after retirement" "$(ch_admin 'SELECT count() FROM beta.t')" "1"
expect "alpha-ch read after beta-ch retirement" "$(ch_rt alpha-ch 'SELECT groupArray(v)[1] FROM alpha.t')" "alpha"
expect "retired beta-ch schedule suspended (F131)" "$(kubectl -n "$NS" get cronjob nagare-appdb-beta-ch -o jsonpath='{.spec.suspend}')" "true"
log "AC-4: rotation changed only alpha-pg runtime; beta-ch retired with its data kept and its schedule suspended; alpha unaffected"

# --- 7. one scheduled run of each alpha backup, ingested, restored into scratch ---
for app in alpha-pg alpha-ch; do
  job="nagare-appdb-$app-$RUN"
  kubectl -n "$NS" create job "$job" --from="cronjob/nagare-appdb-$app" >/dev/null
  kubectl -n "$NS" wait --for=condition=complete "job/$job" --timeout=600s >/dev/null \
    || { kubectl -n "$NS" logs "job/$job" --all-containers --tail=20 >&2 || true; fail "backup run $job did not complete"; }
  uid="$(kubectl -n "$NS" get job "$job" -o jsonpath='{.metadata.uid}')"
  n db app-database backup-receipts "$app" -n "$NS" --backup-id "$uid" --save-plan "$REVIEWS/ingest-$app" >/dev/null
  apply "$REVIEWS/ingest-$app"
  n db app-database restore "$app" -n "$NS" --backup-id "$uid" --restore-id "$RUN" --save-plan "$REVIEWS/restore-$app" >/dev/null
  apply "$REVIEWS/restore-$app"
done
expect "alpha-pg scratch rows" "$(pg_as alpha-pg-migration "alpha_restore_$RUN" "SELECT string_agg(v, '|') FROM t")" "alpha"
expect "alpha-pg scratch runtime read" "$(pg_rt alpha-pg 'SELECT count(*) FROM t' "alpha_restore_$RUN")" "1"
refused "beta-pg runtime on alpha's scratch" pg_rt beta-pg 'SELECT 1' "alpha_restore_$RUN"
expect "alpha-ch scratch rows" "$(ch_as alpha-ch-migration "SELECT groupArray(v)[1] FROM alpha_restore_$RUN.t")" "alpha"
expect "alpha-ch scratch ledger" "$(ch_rt alpha-ch "SELECT count() FROM alpha_ledger_restore_$RUN.l")" "1"
expect "live alpha untouched by the restore" "$(pg_rt alpha-pg "SELECT string_agg(v, '|') FROM t")" "alpha"
expect "beta-pg untouched by the restore" "$(pg_rt beta-pg "SELECT string_agg(v, '|') FROM t")" "beta"
log "AC-5: scheduled runs of alpha-pg and alpha-ch ingested and restored into scratch with their access"
# IR-33 AC-8: the dump carried the reader's grant, yet no reader reaches a scratch database.
refused "alpha-pg reader on alpha's scratch" pg_rt gamma-pg 'SELECT count(*) FROM rv' "alpha_restore_$RUN"
out="$(ch_rt gamma-ch "SELECT count() FROM alpha_restore_$RUN.rv" 2>&1 || true)"
expect "IR-33 AC-8: alpha-ch reader on alpha's scratch" "$(code_of "$out")" "Code: 497"

# --- 7b. EP-206: retire alpha-pg's reader ---
if out="$(n db app-database plan --config "$ROOT/config/AppDatabasesRetired.hs" 2>&1)"; then fail "IR-33 AC-7: a reader still bound was retired"; fi
grep -q 'app-database-reader-in-use' <<<"$out" || { echo "$out" >&2; fail "IR-33 AC-7: retiring a bound reader has the wrong refusal"; }
reader_probe gamma-pg-probe none "$PG_IMAGE" appdb-probe-pg "$PG_TAG" >/dev/null || fail "unbind gamma-pg-probe"
apply "$REVIEWS/worker-gamma-pg-probe-none"
n db app-database plan --config "$ROOT/config/AppDatabasesRetired.hs" --save-plan "$REVIEWS/reader-retired" >/dev/null 2>&1
apply "$REVIEWS/reader-retired"
replan="$(n db app-database plan --config "$ROOT/config/AppDatabasesRetired.hs" 2>/dev/null)"
grep -qx 'no operations' <<<"$replan" || { echo "$replan" >&2; fail "IR-33 AC-7: the re-plan after retiring the reader has operations"; }
refused "the retired alpha-pg reader's login" pg_as alpha-pg-reader-dash alpha 'SELECT 1'
kubectl -n "$NS" get secret alpha-pg-reader-dash >/dev/null || fail "IR-33 AC-7: the retired reader's Secret was removed"
expect "alpha-ch reader after alpha-pg's reader retired" "$(ch_rt gamma-ch 'SELECT count() > 0 FROM alpha.rv')" "1"
expect "alpha-pg runtime after its reader retired" "$(pg_rt alpha-pg "SELECT string_agg(v, '|') FROM t")" "alpha"
log "IR-33 AC-7/AC-8: no reader reaches a scratch restore; alpha-pg's reader retired by declaration, refused while bound, its Secret kept"

# --- 8. status grades every app database; nothing of alpha-pg is past policy (F132) ---
status="$(n server status --skip-vm 2>&1)" || { echo "$status" >&2; fail "server status"; }
for app in alpha-pg alpha-ch beta-pg beta-ch; do
  grep -Eq "recovery point +$NS/$app: " <<<"$status" || { echo "$status" >&2; fail "server status has no recovery point for $NS/$app"; }
  grep -Eq "retention +$NS/$app: " <<<"$status" || { echo "$status" >&2; fail "server status has no retention row for $NS/$app"; }
done
grep -Eq "^ +OK +recovery point +$NS/beta-ch: retired; schedule suspended" <<<"$status" || { echo "$status" >&2; fail "retired beta-ch is not graded retired"; }
# The schedule's own runs since the app databases were created are ingested first: a
# prune refuses while an older run is not ingested.
if ingest="$(n db app-database backup-receipts alpha-pg -n "$NS" --all --save-plan "$REVIEWS/ingest-all-alpha-pg" 2>&1)"; then
  apply "$REVIEWS/ingest-all-alpha-pg"
else
  grep -q "no verified scheduled run awaits ingestion" <<<"$ingest" || { echo "$ingest" >&2; fail "ingest alpha-pg's scheduled runs"; }
fi
if prune="$(n db app-database prune-scheduled-backups alpha-pg -n "$NS" --save-plan "$REVIEWS/prune-alpha-pg" 2>&1)"; then
  fail "a prune of alpha-pg's fresh runs was reviewed"
fi
grep -q "no accepted scheduled backup is past the retention policy" <<<"$prune" || { echo "$prune" >&2; fail "alpha-pg prune review"; }
log "F132: status grades all four app databases' recovery points, beta-ch retired; alpha-pg has no runs past policy"

# --- 8a. EP-207: a run taken before its schedule changed ---
# A fresh app database per run, planned from its own config, so the four above are untouched.
ZETA="zeta-$RUN"
zeta_config() { # file, logical databases as a Haskell list
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

main :: IO ()
main =
  emitAppDatabases
    [ AppDatabase
        { name = ok (mkAppDatabaseName "$ZETA")
        , logicalKey = Nothing
        , server = ok (mkDatabaseName "smoke-ch")
        , engine = ClickHouse
        , namespace = ok (mkNamespace "personal")
        , logicalDatabases = ok (mapM mkLogicalDatabaseName ($2))
        , access = noAppDatabaseAccess
        }
    ]
EOF
}
zeta_config "$ROOT/config/Zeta.hs" '"z" :| []'
zeta_config "$ROOT/config/ZetaWider.hs" '"z" :| ["z_extra"]'
scheduled_run() { # app database; prints the completed run's Job UID
  local job="nagare-appdb-$1-$2"
  kubectl -n "$NS" create job "$job" --from="cronjob/nagare-appdb-$1" >/dev/null
  kubectl -n "$NS" wait --for=condition=complete "job/$job" --timeout=600s >/dev/null \
    || { kubectl -n "$NS" logs "job/$job" --all-containers --tail=20 >&2 || true; fail "backup run $job did not complete"; }
  kubectl -n "$NS" get job "$job" -o jsonpath='{.metadata.uid}'
}
n db app-database plan --config "$ROOT/config/Zeta.hs" --save-plan "$REVIEWS/zeta" >/dev/null 2>&1 || fail "plan $ZETA"
apply "$REVIEWS/zeta"
ch_as "$ZETA-migration" "CREATE TABLE z.t (v String) ENGINE = MergeTree ORDER BY v"
ch_as "$ZETA-migration" "INSERT INTO z.t VALUES ('before')"
before_run="$(scheduled_run "$ZETA" before)"
# The schedule changes: a logical database is added after the run.
n db app-database plan --config "$ROOT/config/ZetaWider.hs" --save-plan "$REVIEWS/zeta-wider" >/dev/null 2>&1 || fail "plan the wider $ZETA"
apply "$REVIEWS/zeta-wider"
grep -q z_extra <<<"$(kubectl -n "$NS" get cronjob "nagare-appdb-$ZETA" -o json)" || fail "EP-207: the wider declaration did not change the schedule"
n db app-database backup-receipts "$ZETA" -n "$NS" --backup-id "$before_run" --save-plan "$REVIEWS/zeta-ingest-before" >/dev/null 2>&1 \
  || fail "EP-207: the run taken before the schedule changed was not ingested"
apply "$REVIEWS/zeta-ingest-before"
n db app-database restore "$ZETA" -n "$NS" --backup-id "$before_run" --restore-id "$RUN" --save-plan "$REVIEWS/zeta-restore" >/dev/null 2>&1 \
  || fail "EP-207: the run taken before the schedule changed was not restored"
apply "$REVIEWS/zeta-restore"
expect "EP-207: the restored pre-change run" "$(ch_admin "SELECT groupArray(v)[1] FROM z_restore_$RUN.t")" "before"
expect "EP-207: no scratch for a database the run does not hold" "$(ch_admin "SELECT count() FROM system.databases WHERE name = 'z_extra_restore_$RUN'")" "0"
after_run="$(scheduled_run "$ZETA" after)"
n db app-database backup-receipts "$ZETA" -n "$NS" --backup-id "$after_run" --save-plan "$REVIEWS/zeta-ingest-after" >/dev/null 2>&1 || fail "ingest the run after the change"
apply "$REVIEWS/zeta-ingest-after"
if prune="$(n db app-database prune-scheduled-backups "$ZETA" -n "$NS" --save-plan "$REVIEWS/zeta-prune" 2>&1)"; then
  fail "EP-207: a prune of two fresh runs was reviewed"
fi
grep -q "no accepted scheduled backup is past the retention policy" <<<"$prune" || { echo "$prune" >&2; fail "EP-207: the prune review refused a run of an earlier schedule revision"; }
n db app-database retire "$ZETA" -n "$NS" --save-plan "$REVIEWS/zeta-retire" >/dev/null
apply "$REVIEWS/zeta-retire"
log "EP-207: a run taken before a logical database was added ingested, restored only its own database and kept prune open; $ZETA retired"

echo "app-database smoke: PASS"
