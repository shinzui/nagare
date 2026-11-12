#!/usr/bin/env bash
# scripts/local-secret-scope-smoke.sh (EP-261 M4, IR-44) — the managed store, per workload.
#
# On a bootstrapped LOCAL context (mode=local, a k3d cluster):
#   1. one image that serves HTTP and has a shell, published through review, and four keys
#      written to the store of the Application `scoped` with a reviewed `secret sync`;
#   2. `scoped`, whose web service, worker and pre-deploy hook all set NoManagedEnv and each
#      reference their own keys of nagare-secret-scoped-runtime, planned with that one Secret
#      resource and applied. No live container has an envFrom of the store, each container's
#      env names are its declared ones, each workload reads its keys and no other, and the
#      saved review names the one Secret (IR-44 AC-1, AC-2);
#   3. `plain`, a web service and a hook with no opt-out, deployed by the previous release's
#      nagarectl and planned again by this one: no operations (AC-3). Skipped with a note
#      unless NAGARECTL_PREVIOUS names that nagarectl;
#   4. `shared`, whose web service and worker do not opt out and carry other names than the
#      Application: a key written with `secret set shared` reaches both (AC-4);
#   5. secret-scope smoke: PASS.
#
# Usage (from an empty environment; the context names the cluster, never the ambient shell):
#   NAGARE_SMOKE_CONTEXT=NAME [NAGARECTL=/path/to/nagarectl] [NAGARECTL_PREVIOUS=/path/to/nagarectl] \
#     scripts/local-secret-scope-smoke.sh
# The context's kubeconfig is $XDG_CONFIG_HOME/nagare/kubeconfigs/NAME.yaml. Reviews, configs
# and the image archive live under NAGARE_SMOKE_ROOT (default
# $XDG_STATE_HOME/nagare/secret-scope-smoke/NAME), so a rerun reuses the publication.
set -euo pipefail

CTX="${NAGARE_SMOKE_CONTEXT:?name a mode=local context in NAGARE_SMOKE_CONTEXT}"
NAGARECTL="${NAGARECTL:-$(command -v nagarectl)}"
PREVIOUS="${NAGARECTL_PREVIOUS:-}"
NS=personal
ROOT="${NAGARE_SMOKE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/nagare/secret-scope-smoke/$CTX}"
RUN="s$(date -u +%m%d%H%M%S)"
REVIEWS="$ROOT/runs/$RUN"
mkdir -p "$REVIEWS" "$ROOT/config" "$ROOT/images" "$ROOT/build"

log() { printf '%s secret-scope smoke: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "secret-scope smoke: FAIL: $*" >&2; exit 1; }
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

# --- 1. the image and the store ---
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
cat > "$ROOT/build/Dockerfile" <<'EOF'
FROM busybox:1.37
RUN mkdir /www && echo secret-scope > /www/index.html
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
EOF
# Built once per daemon: a rebuild gets a new image ID, and with it a new tag and release.
docker image inspect secret-scope-smoke:local >/dev/null 2>&1 || docker build -q -t secret-scope-smoke:local "$ROOT/build" >/dev/null
IMAGE="$(publish secret-scope-smoke:local secret-scope-smoke)"
[ -n "$IMAGE" ] || fail "the image review named no resource"
TAG="$(docker image inspect secret-scope-smoke:local --format '{{.Id}}' | cut -d: -f2 | cut -c1-12)"
REPO="${NAGARE_REGISTRY_HOST}/${CLOUDSDK_CORE_PROJECT}/${NAGARE_ARTIFACT_REGISTRY_ID}/secret-scope-smoke"

# An Application of a web service, optionally a worker, and a pre-deploy hook. It is written
# with presets only unless a workload opts out, so the previous release loads `plain` too.
config() { # app, service, worker or "", opt-out (yes|no), hook shell command
  local app="$1" svc="$2" wrk="$3" out="$4" hook="$5" import="" opt="" env_of=""
  if [ "$out" = yes ]; then
    import="import Nagare.Dsl.Types (ManagedEnv (..))"
    opt="& #managedEnv .~ NoManagedEnv"
    env_of="keys"
  else
    env_of="noKeys"
  fi
  mkdir -p "$ROOT/config/$app"
  cat > "$ROOT/config/$app/Config.hs" <<EOF
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Lens ((&), (.~))
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Build (BuildSpec (PrebuiltImage), mkTag)
import Nagare.Dsl.Config (emitApplication)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Task (mkTask, scheduledTask)
import Nagare.Dsl.Types (EnvName, EnvVar (EnvSecretRef), ScopedEnvVar, mkEnvName, mkImageRef, mkNamespace, mkScale, mkSecretName, mkServiceName, runtimeScoped)
$import
import Nagare.Dsl.Worker (mkCommand, webWorker)

keys, noKeys :: [Text] -> Map.Map EnvName ScopedEnvVar
keys names = either (error . show) id \$ do
  secret <- mkSecretName "nagare-secret-$app-runtime"
  envNames <- traverse mkEnvName names
  pure (Map.fromList [(envName, runtimeScoped (EnvSecretRef secret)) | envName <- envNames])
noKeys = const Map.empty

main :: IO ()
main = either (ioError . userError . Text.unpack) emitApplication \$ do
  ns <- mkNamespace "$NS"
  image' <- mkImageRef "$REPO"
  tag <- mkTag "$TAG"
  appName <- mkServiceName "$app"
  one <- mkScale 1 1
  idle <- first (Text.pack . show) (mkCommand ["sh", "-c", "while :; do sleep 3600; done"])
  service <- webService "$svc" "$REPO"
  workers <- traverse (\\w -> first Text.pack (webWorker w "$REPO")) [w | w <- ["$wrk"], w /= ("" :: Text)]
  hook0 <- scheduledTask "$app-migrate" "0 0 * * *" "$REPO" "true"
  hook <- mkTask (hook0 & #image .~ Nothing & #app .~ Just appName & #command .~ ["sh", "-c", "$hook"] & #env .~ $env_of ["MIGRATION_URL"] $opt)
  mkApplication
    Application
      { name = appName
      , logicalKey = Nothing
      , namespace = ns
      , image = image'
      , env = Map.empty
      , databases = []
      , brokers = []
      , access = Nothing
      , service = Just (service & #build .~ PrebuiltImage tag & #scale .~ Just one & #env .~ $env_of ["WEB_TOKEN", "SHARED_KEY"] $opt)
      , workers = [w & #build .~ PrebuiltImage tag & #command .~ Just idle & #env .~ $env_of ["WORKER_TOKEN", "SHARED_KEY"] $opt | w <- workers]
      , tasks = [hook]
      }
EOF
}
deploy() { # nagarectl, app, review name, extra arguments
  local ctl="$1" app="$2" review="$REVIEWS/$3"; shift 3
  "$ctl" --context "$CTX" app deploy -f "$ROOT/config/$app/Config.hs" --tag "$TAG" --image-resource "$IMAGE" \
    --hook-no-data-effects "$app-migrate" --save-plan "$review" "$@" > "$review.plan.log" 2>&1 \
    || { tail -5 "$review.plan.log" >&2; fail "plan $review"; }
}
# The names and envFrom sources of one workload's own container, from its live Pod. Knative
# adds PORT and K_* to a web container; Nagare adds NAGARE_*.
pod_env() { # label selector, container name
  kubectl -n "$NS" get pod -l "$1" -o json | python3 -I -c '
import json, sys
pods = [p for p in json.load(sys.stdin)["items"] if not p["metadata"].get("deletionTimestamp")]
if not pods: sys.exit("no pod for " + sys.argv[1])
names, sources = set(), set()
for pod in pods:
    for c in pod["spec"]["containers"] + pod["spec"].get("initContainers", []):
        for f in c.get("envFrom", []):
            sources.update(ref["name"] for ref in f.values() if isinstance(ref, dict) and "name" in ref)
        if c["name"] == sys.argv[2]:
            names.update(e["name"] for e in c.get("env", []))
names = sorted(x for x in names if x != "PORT" and not x.startswith(("K_", "NAGARE_")))
print(" ".join(names) + "|" + " ".join(sorted(sources)))' "$1" "$2"
}
expect() { [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"; }
value_in() { kubectl -n "$NS" exec "$1" -c "$2" -- sh -c "echo \"\${$3:-}\""; }

STORE=application:secret-scoped-runtime/runtime-secret/secret
# shellcheck disable=SC2016  # the hook's shell expands these, in its Pod
config scoped scoped-web scoped-worker yes '[ x$MIGRATION_URL = xmigration-value ] && [ -z ${WEB_TOKEN:-}${WORKER_TOKEN:-}${SHARED_KEY:-} ] && echo hook read only MIGRATION_URL'
printf 'WEB_TOKEN=web-value\nWORKER_TOKEN=worker-value\nSHARED_KEY=shared-value\nMIGRATION_URL=migration-value\n' > "$REVIEWS/scoped.env"
n secret sync scoped -f "$ROOT/config/scoped/Config.hs" --file "$REVIEWS/scoped.env" --version "$RUN" --save-plan "$REVIEWS/secret-scoped" >/dev/null
apply "$REVIEWS/secret-scoped"
log "four keys written to nagare-secret-scoped-runtime by a reviewed secret sync"

# --- 2. every workload of `scoped` opts out (AC-1, AC-2) ---
deploy "$NAGARECTL" scoped app-scoped --env-secret-resource "$STORE"
# The review saves every scope; the Application's own names its members' dependencies.
python3 -I -c '
import glob, json, sys
review, store = sys.argv[1], sys.argv[2]
scopes = [s for s in map(lambda f: json.load(open(f)), glob.glob(review + "/scopes/*.json")) if s["scope"] == {"kind": "Application", "name": "scoped"}]
if len(scopes) != 1: sys.exit("the review holds %d scopes named scoped" % len(scopes))
readers, secrets = set(), set()
for bundle in scopes[0]["bundles"]:
    for declaration in bundle["declarations"]:
        member = declaration["contents"]
        kind = member["address"]["contents"][2]
        for dependency in member["dependencies"]:
            if dependency["contents"].endswith("/secret"):
                secrets.add(dependency["contents"]); readers.add(kind)
if secrets != {store}: sys.exit("Secret dependencies: %s" % sorted(secrets))
if readers != {"service", "deployment", "cronjob"}: sys.exit("members depending on the Secret: %s" % sorted(readers))
' "$REVIEWS/app-scoped" "$STORE" || fail "AC-2: the saved review does not record the one Secret dependency"
apply "$REVIEWS/app-scoped"
kubectl -n "$NS" wait --for=condition=Ready ksvc/scoped-web --timeout=300s >/dev/null
kubectl -n "$NS" rollout status deployment/scoped-worker --timeout=300s >/dev/null
hook_job="$(kubectl -n "$NS" get job -l nagare.dev/app=scoped -o name | head -1)"
[ -n "$hook_job" ] || fail "AC-1: no hook Job for scoped"
kubectl -n "$NS" wait --for=condition=Complete "$hook_job" --timeout=300s >/dev/null
expect "AC-1 web" "$(pod_env serving.knative.dev/service=scoped-web user-container)" "SHARED_KEY WEB_TOKEN|"
expect "AC-1 worker" "$(pod_env nagare.dev/worker=scoped-worker scoped-worker)" "SHARED_KEY WORKER_TOKEN|"
expect "AC-1 hook" "$(pod_env "job-name=${hook_job#job.batch/}" scoped-migrate)" "MIGRATION_URL|"
log "AC-1: no container of scoped has an envFrom; each names only its declared keys"
kubectl -n "$NS" logs "$hook_job" | grep -qx 'hook read only MIGRATION_URL' || fail "AC-2: the hook did not report its one key"
worker_pod="deployment/scoped-worker"
web_pod="$(kubectl -n "$NS" get pod -l serving.knative.dev/service=scoped-web -o name | head -1)"
expect "AC-2 worker WORKER_TOKEN" "$(value_in "$worker_pod" scoped-worker WORKER_TOKEN)" worker-value
expect "AC-2 worker SHARED_KEY" "$(value_in "$worker_pod" scoped-worker SHARED_KEY)" shared-value
expect "AC-2 worker WEB_TOKEN" "$(value_in "$worker_pod" scoped-worker WEB_TOKEN)" ""
expect "AC-2 worker MIGRATION_URL" "$(value_in "$worker_pod" scoped-worker MIGRATION_URL)" ""
expect "AC-2 web WEB_TOKEN" "$(value_in "$web_pod" user-container WEB_TOKEN)" web-value
expect "AC-2 web SHARED_KEY" "$(value_in "$web_pod" user-container SHARED_KEY)" shared-value
expect "AC-2 web WORKER_TOKEN" "$(value_in "$web_pod" user-container WORKER_TOKEN)" ""
expect "AC-2 web MIGRATION_URL" "$(value_in "$web_pod" user-container MIGRATION_URL)" ""
log "AC-2: each workload reads its own keys of the one runtime Secret and no other; the review names only $STORE"

# --- 3. a workload that does not opt out is unchanged from the previous release (AC-3) ---
operations() { python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["operations"]))' "$1/review.json"; }
if [ -n "$PREVIOUS" ]; then
  config plain plain "" no 'echo plain hook'
  # The previous release brings plain to this tag; on a rerun that is already a no-op.
  deploy "$PREVIOUS" plain app-plain-previous
  "$PREVIOUS" --context "$CTX" inventory apply "$REVIEWS/app-plain-previous" --yes > "$REVIEWS/app-plain-previous.apply.log" 2>&1 \
    || { tail -5 "$REVIEWS/app-plain-previous.apply.log" >&2; fail "apply plain with the previous nagarectl"; }
  kubectl -n "$NS" wait --for=condition=Ready ksvc/plain --timeout=300s >/dev/null
  deploy "$NAGARECTL" plain app-plain
  expect "AC-3 operations" "$(operations "$REVIEWS/app-plain")" 0
  log "AC-3: plain, deployed by $("$PREVIOUS" version | head -1), replans with no operations"
else
  log "AC-3: SKIPPED (name the previous release's nagarectl in NAGARECTL_PREVIOUS)"
fi

# --- 4. an Application's service and worker inherit the Application's store (AC-4) ---
config shared shared-web shared-worker no 'echo shared hook'
printf 'inherited-%s' "$RUN" | n secret set shared -f "$ROOT/config/shared/Config.hs" INHERITED_KEY --version "$RUN" --save-plan "$REVIEWS/secret-shared" >/dev/null
apply "$REVIEWS/secret-shared"
deploy "$NAGARECTL" shared app-shared
apply "$REVIEWS/app-shared"
kubectl -n "$NS" wait --for=condition=Ready ksvc/shared-web --timeout=300s >/dev/null
kubectl -n "$NS" rollout status deployment/shared-worker --timeout=300s >/dev/null
expect "AC-4 worker store" "$(pod_env nagare.dev/worker=shared-worker shared-worker)" "|nagare-env-shared-runtime nagare-secret-shared-runtime"
# A Pod started before this run's key keeps its old environment; its replacement reads the
# store. The Pod is replaced, not the Deployment rolled: `kubectl rollout restart` would own
# a field of the reviewed object and the next reviewed apply would refuse.
kubectl -n "$NS" delete pod -l nagare.dev/worker=shared-worker --wait=true >/dev/null
kubectl -n "$NS" rollout status deployment/shared-worker --timeout=300s >/dev/null
expect "AC-4 worker INHERITED_KEY" "$(value_in deployment/shared-worker shared-worker INHERITED_KEY)" "inherited-$RUN"
web_store="$(pod_env serving.knative.dev/service=shared-web user-container)"
case "$web_store" in *"|nagare-env-shared-runtime nagare-secret-shared-runtime") ;; *) fail "AC-4 web store: got '$web_store'" ;; esac
log "AC-4: secret set shared reaches shared-worker; shared-web and shared-worker name the Application's store"

echo "secret-scope smoke: PASS"
