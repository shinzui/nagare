#!/usr/bin/env bash
# scripts/local-app-database-smoke.sh (EP-202 M7) — app databases on shared servers, natively.
#
# On a bootstrapped LOCAL context (mode=local, a k3d cluster), with the packaged nagarectl:
#   1. servers smoke-pg and smoke-ch;
#   2. app databases alpha-pg, alpha-ch, beta-pg and beta-ch, planned and applied;
#   3. a re-plan has no operations;
#   4. four probe Workers, each binding one app database, on the servers' own images;
#   5. own-database read and write, and every cross-app denial;
#   5b. EP-204: reviewed exceptions and ceilings on alpha-ch and a connection limit and
#      pg_monitor on alpha-pg hold, beta is unaffected, and removing an exception revokes it;
#   6. rotate alpha-pg's runtime user and retire beta-ch, the other apps unchanged;
#   7. one scheduled backup run of alpha-pg and alpha-ch, ingested and restored into scratch;
#   8. server status grades all four app databases' recovery points (beta-ch retired), and a
#      prune review of alpha-pg has no runs past policy (EP-203);
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
import Nagare.Dsl.Types (mkAppDatabaseName, mkDatabaseName, mkNamespace)

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

alphaCh, alphaPg :: AppDatabaseAccess
alphaCh
  | stage == "none" = noAppDatabaseAccess
  | otherwise =
      noAppDatabaseAccess
        & #runtime .~ UserAccess ([SystemParts] <> [SystemStoragePolicies | stage == "declared"] <> [ArbitraryTemporaryTables]) (ceilings 268435456 5 2)
        & #migration .~ UserAccess [] (ceilings 4294967296 600 4)
alphaPg
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
# A rerun starts from no reviewed access: PGMQ's grants an earlier run left would be drift.
if kubectl -n "$NS" get secret alpha-pg-migration >/dev/null 2>&1; then
  kubectl -n "$NS" exec smoke-pg-0 -- env PGPASSWORD="$(secret alpha-pg-migration POSTGRES_PASSWORD)" \
    psql -h smoke-pg -U "$(secret alpha-pg-migration POSTGRES_USER)" -d alpha -v ON_ERROR_STOP=1 -tAc 'DROP SCHEMA IF EXISTS pgmq CASCADE' >/dev/null
fi
if ! n db app-database plan --config "$ROOT/config/AppDatabases.hs" | grep -qx 'no operations'; then
  n db app-database plan --config "$ROOT/config/AppDatabases.hs" --save-plan "$REVIEWS/app-databases"
  apply "$REVIEWS/app-databases"
fi

# --- 3. converged ---
replan="$(n db app-database plan --config "$ROOT/config/AppDatabases.hs")"
grep -qx 'no operations' <<<"$replan" || { echo "$replan" >&2; fail "the re-plan has operations"; }
log "AC-1/AC-4: four app databases on one server per engine; re-plan: no operations"
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

echo "app-database smoke: PASS"
