#!/usr/bin/env bash
# EP-188 M3: the native proof of MasterPlan 27 on a disposable local context. From the
# candidate nagarectl and nagare-harness and the auth images built from this tree on a
# disposable Docker daemon: bootstrap the context, package, publish and deploy the protected
# static-site example, then drive the real Shomei login, reviewed user and team grants,
# the enforcer, the effective-access diagnostic, a preview, a rollback and the origin
# through the harness route check and curl over the local CA. Every step stops at its
# first refusal. The record is evidence/site-access-drill.json under the drill root; it
# names revisions, image digests and the active schema, never a secret.
set -euo pipefail

: "${DOCKER_HOST:?the disposable Docker daemon socket, never the shared cp3 daemon}"
: "${NAGARE_DRILL_NAGARECTL:?the candidate nagarectl}"
: "${NAGARE_DRILL_IMAGE_TAG:?the tag of the images built from this tree on this daemon}"
# EP-198: NAGARE_DRILL_ADMIN_API=1 enables the admin API in the context and pins its image;
# NAGARE_DRILL_BOOTSTRAP_ONLY=1 stops once the platform has converged (scripts/admin-api-drill.sh
# continues from there), and needs neither the harness nor the GHC environment.
ADMIN_API="${NAGARE_DRILL_ADMIN_API:-0}"
BOOTSTRAP_ONLY="${NAGARE_DRILL_BOOTSTRAP_ONLY:-0}"
[ "$BOOTSTRAP_ONLY" = 1 ] || : "${NAGARE_DRILL_HARNESS:?the candidate nagare-harness}"
: "${NAGARE_DRILL_IMAGE_TAG:?the tag of the en, shomei and nagare-access images built from this tree on this daemon}"
[ "$BOOTSTRAP_ONLY" = 1 ] || : "${NAGARE_DRILL_GHC_ENV:?the GHC package environment that resolves nagare-dsl}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${NAGARE_DRILL_ROOT:-$(mktemp -d /private/tmp/nagare-site-access.XXXXXX)}"
CTX="${NAGARE_DRILL_CONTEXT:-site-access}"
NS=personal
SITE=protected-static-site
BASE=127-0-0-1.sslip.io
HOST="$SITE.$NS.$BASE"
PREVIEW=drill
PREVIEW_HOST="$PREVIEW.$SITE.preview.$BASE"
TEAM=engineering
OTHER=finance
EXAMPLE="$REPO/cluster/examples/$SITE"
TAG="$NAGARE_DRILL_IMAGE_TAG"
STAGES_MAX=12
INGRESS_PORT="${NAGARE_DRILL_INGRESS_PORT:-18443}"
HARNESS_INGRESS_PORT=$((INGRESS_PORT + 1))
INGRESS_HTTP_PORT=$((INGRESS_PORT + 2))
FORWARD_PORT="${NAGARE_DRILL_FORWARD_PORT:-15213}"

# The ambient shell may carry a context, a payload root and a kubeconfig from direnv; the
# drill uses only its own root and the candidate's packaged payload.
for v in $(env | sed -n "s/^\(NAGARE_[A-Z_]*\|CLOUDSDK_[A-Z_]*\|PULUMI_[A-Z_]*\|KUBECONFIG\|SOPS_AGE_KEY_FILE\)=.*/\1/p"); do
  case "$v" in NAGARE_DRILL_*) ;; *) unset "$v" ;; esac
done
export XDG_CONFIG_HOME="$ROOT/config" XDG_STATE_HOME="$ROOT/state" XDG_CACHE_HOME="$ROOT/cache"
mkdir -p "$ROOT"/{config,state,cache,reviews,evidence,sops/age,site}
chmod 700 "$ROOT" "$ROOT/sops" "$ROOT/sops/age"
EV="$ROOT/evidence"
log() { printf '%s drill: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
N() { "$NAGARE_DRILL_NAGARECTL" --context "$CTX" "$@"; }
record() { printf '%s\t%s\n' "$1" "$2" >> "$EV/observations.tsv"; log "$1: $2"; }
expect() { # label got wanted
  [ "$2" = "$3" ] || { echo "drill: $1: got $2, wanted $3" >&2; exit 1; }
  record "$1" "$2"
}
operations() { python3 -I -c 'import json,sys; ops=json.load(open(sys.argv[1]))["operations"]; print(sum(1 for o in ops if sys.argv[2] == "all" or (o.get("operation", o).get("action") or {}).get("tag") != "VerifyResource"))' "$1/review.json" "${2:-all}"; }
reaccepts() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); base={json.dumps(e["scope"],sort_keys=True): e["revision"] for e in d["baseRevisions"]}; print(sum(1 for e in d["desiredRevisions"] if e["scope"].get("name") != "bootstrap-stamp" and base.get(json.dumps(e["scope"],sort_keys=True)) != e["revision"]))' "$1/review.json"; }
resume_ambiguous() { # apply-log
  local applyLog="$1" tx n
  tx="$(tail -2 "$applyLog" | sed -n "s/^ambiguous \(tx-[0-9a-f]*\) at .*/\1/p" | tail -1)"
  [ -n "$tx" ] || return 1
  for n in $(seq 1 12); do
    sleep 20
    log "resume $n of $tx"
    if N inventory resume "$tx" --yes >> "$applyLog" 2>&1; then return 0; fi
    tail -2 "$applyLog" | grep -q "^ambiguous $tx at " || return 1
  done
  return 1
}
review_apply() { # dir
  N inventory apply "$1" --yes > "$1.apply.log" 2>&1 || resume_ambiguous "$1.apply.log" || { echo "apply of $1 failed: $(tail -3 "$1.apply.log")" >&2; exit 1; }
}

# --- 0. the daemon is disposable; its k3d state is replaced ---
[ "$DOCKER_HOST" != "unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock" ] || { echo "refusing the shared cp3 daemon" >&2; exit 1; }
if [ "${NAGARE_DRILL_SKIP_BOOTSTRAP:-0}" = 1 ]; then
  # Continue in a root whose context is already bootstrapped: its images, forward and key stand.
  export SOPS_AGE_KEY_FILE="$ROOT/sops/age/keys.txt"
  set -a; . "$ROOT/images.env"; set +a
  export NAGARE_LOCAL_REGISTRY_FORWARD="127.0.0.1:$FORWARD_PORT"
  candidate="$(N version --json)"
  log "continuing in $ROOT on the bootstrapped context $CTX; candidate $(printf '%s' "$candidate" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("version"), d.get("revision"))')"
else
AUTH_REPOS=(en shomei nagare-access)
[ "$ADMIN_API" != 1 ] || AUTH_REPOS+=(nagare-admin-api)
# The admin API's local store is mounted from the workstation through the daemon's VM, which
# shares only the home directory.
[ "$ADMIN_API" != 1 ] || case "$ROOT" in "$HOME"/*) ;; *) echo "an admin API drill root must be under $HOME, which the VM mounts" >&2; exit 1 ;; esac
for repo in "${AUTH_REPOS[@]}"; do
  docker image inspect "k3d-registry.localhost:5000/$repo:$TAG" >/dev/null 2>&1 || { echo "this daemon has no $repo:$TAG image built from this tree" >&2; exit 1; }
done
if docker ps -a --format '{{.Names}}' | grep -q '^k3d-\|^registry-forward$'; then
  [ "${NAGARE_DRILL_RESET:-0}" = 1 ] || { echo "the daemon already holds a k3d cluster; set NAGARE_DRILL_RESET=1 to delete it" >&2; exit 1; }
  docker rm -f registry-forward >/dev/null 2>&1 || true
  k3d cluster delete nagare-local >/dev/null 2>&1 || true
  k3d registry delete k3d-registry.localhost >/dev/null 2>&1 || true
fi
candidate="$(N version --json 2>/dev/null || "$NAGARE_DRILL_NAGARECTL" version --json)"
log "root $ROOT; candidate $(printf '%s' "$candidate" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("version"), d.get("revision"))')"

# --- 1. context-owned observability secrets, encrypted to a fresh age key ---
export SOPS_AGE_KEY_FILE="$ROOT/sops/age/keys.txt"
(umask 077; age-keygen -o "$SOPS_AGE_KEY_FILE" >/dev/null 2>&1)
recipient="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
secrets="$XDG_CONFIG_HOME/nagare/cluster-secrets/$CTX"
mkdir -p "$secrets"
printf 'creation_rules:\n  - age: %s\n' "$recipient" > "$secrets/.sops.yaml"
(umask 077; printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: grafana-admin\n  namespace: monitoring\nstringData:\n  admin-user: admin\n  admin-password: %s\n' "$(head -c 24 /dev/urandom | base64 | tr -d '/+=')" > "$secrets/grafana-admin.yaml")
sops --config "$secrets/.sops.yaml" --encrypt --in-place "$secrets/grafana-admin.yaml"

# --- 2. the disposable local context ---
"$NAGARE_DRILL_NAGARECTL" context create "$CTX" --mode local --registry-host k3d-registry.localhost:5000 --base-domain "$BASE" \
  --target-platform linux/arm64 --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups --use | tail -1
if [ "$ADMIN_API" = 1 ]; then
  profile="$XDG_CONFIG_HOME/nagare/contexts/$CTX.env"
  if grep -q '^export NAGARE_ADMIN_API_ENABLED=' "$profile"; then
    sed -i.bak 's/^export NAGARE_ADMIN_API_ENABLED=.*/export NAGARE_ADMIN_API_ENABLED=1/' "$profile" && rm -f "$profile.bak"
  else
    printf 'export NAGARE_ADMIN_API_ENABLED=1\n' >> "$profile"
  fi
  "$NAGARE_DRILL_NAGARECTL" --context "$CTX" context env | grep -q 'NAGARE_ADMIN_API_ENABLED=.*1' || { echo "the context does not enable the admin API" >&2; exit 1; }
fi

# --- 3. the images the platform pins: this tree's auth plane, the pinned object store ---
seed_images() {
  local pair repo tag digest
  local pairs=("en:$TAG" "shomei:$TAG" "nagare-access:$TAG")
  [ "$ADMIN_API" != 1 ] || pairs+=("nagare-admin-api:$TAG")
  for pair in "${pairs[@]}" nagare-minio:release-2025-09-07-arm64 nagare-mc:release-2025-08-13-arm64; do
    repo="${pair%%:*}"; tag="${pair#*:}"
    docker image inspect "k3d-registry.localhost:5000/$repo:$tag" >/dev/null 2>&1 \
      || docker --host "${NAGARE_DRILL_IMAGE_DAEMON:?this daemon lacks $repo:$tag; set NAGARE_DRILL_IMAGE_DAEMON}" save "k3d-registry.localhost:5000/$repo:$tag" | docker load >/dev/null
    docker tag "k3d-registry.localhost:5000/$repo:$tag" "localhost:5000/$repo:$tag"
    digest="$(docker push "localhost:5000/$repo:$tag" | sed -n 's/.*digest: \(sha256:[0-9a-f]*\).*/\1/p' | tail -1)"
    [ -n "$digest" ] || { echo "no digest for $repo" >&2; exit 1; }
    case "$repo" in
      en) export NAGARE_AUTH_EN_IMAGE="k3d-registry.localhost:5000/$repo@$digest" ;;
      shomei) export NAGARE_AUTH_SHOMEI_IMAGE="k3d-registry.localhost:5000/$repo@$digest" ;;
      nagare-access) export NAGARE_AUTH_ACCESS_IMAGE="k3d-registry.localhost:5000/$repo@$digest" ;;
      nagare-admin-api) export NAGARE_ADMIN_API_IMAGE="k3d-registry.localhost:5000/$repo@$digest" ;;
      nagare-minio) export NAGARE_LOCAL_MINIO_IMAGE="k3d-registry.localhost:5000/$repo@$digest" ;;
      nagare-mc) export NAGARE_LOCAL_MC_IMAGE="k3d-registry.localhost:5000/$repo@$digest" ;;
    esac
  done
  env | grep -E '^NAGARE_(AUTH_[A-Z]+|LOCAL_(MINIO|MC)|ADMIN_API)_IMAGE=' > "$ROOT/images.env"
  # Host-side publications reach the registry through a loopback forward (port 5000 on
  # this Mac belongs to AirPlay); the artifact transport honours it.
  [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FORWARD_PORT/v2/")" = 000 ] || { echo "127.0.0.1:$FORWARD_PORT is already in use on the host; set NAGARE_DRILL_FORWARD_PORT" >&2; exit 1; }
  docker rm -f registry-forward >/dev/null 2>&1 || true
  docker run -d --name registry-forward --network k3d-nagare-local -p "127.0.0.1:$FORWARD_PORT:5000" alpine/socat TCP-LISTEN:5000,fork,reuseaddr TCP:k3d-registry.localhost:5000 >/dev/null
  for _ in $(seq 1 30); do curl -s -m 2 -o /dev/null "http://127.0.0.1:$FORWARD_PORT/v2/" && break; sleep 1; done
  [ "$(curl -s -m 3 "http://127.0.0.1:$FORWARD_PORT/v2/_catalog")" = "$(docker exec k3d-registry.localhost wget -q -O - http://localhost:5000/v2/_catalog)" ] \
    || { echo "the registry forward on 127.0.0.1:$FORWARD_PORT does not answer with this daemon's registry" >&2; exit 1; }
  export NAGARE_LOCAL_REGISTRY_FORWARD="127.0.0.1:$FORWARD_PORT"
}

# --- 4. bootstrap until a review has no operations ---
for n in $(seq 1 "$STAGES_MAX"); do
  review="$ROOT/reviews/bootstrap-$n"
  N platform bootstrap plan --out "$review" > "$review.plan.log" 2>&1 || { echo "bootstrap plan $n refused: $(tail -2 "$review.plan.log")" >&2; exit 1; }
  ops="$(operations "$review" all)"; moves="$(reaccepts "$review")"
  log "bootstrap stage $n: $ops operations, re-accepts scopes: $moves"
  if [ "$ops" = 0 ] && [ "$moves" = 0 ]; then break; fi
  N platform bootstrap apply "$review" --yes > "$review.apply.log" 2>&1 || resume_ambiguous "$review.apply.log" || { echo "bootstrap apply $n failed: $(tail -3 "$review.apply.log")" >&2; exit 1; }
  if [ ! -f "$ROOT/images.env" ] && docker ps --format '{{.Names}}' | grep -q '^k3d-registry'; then
    seed_images; log "images seeded: $(wc -l < "$ROOT/images.env") pins"
  fi
  [ "$n" != "$STAGES_MAX" ] || { echo "bootstrap did not converge in $STAGES_MAX stages" >&2; exit 1; }
done
fi
export KUBECONFIG="$XDG_CONFIG_HOME/nagare/kubeconfigs/$CTX.yaml"
KUBE="$(kubectl config current-context)"
kubectl --context "$KUBE" -n nagare-system rollout status deploy/shomei --timeout=300s >/dev/null
kubectl --context "$KUBE" -n nagare-system rollout status deploy/en --timeout=300s >/dev/null
kubectl --context "$KUBE" -n nagare-system wait ksvc/nagare-access --for=condition=Ready --timeout=300s >/dev/null
N platform status --json > "$EV/platform.json"

# --- 5. the active schema, the digest that rolled en, and the exact images ---
apiKey="$(kubectl --context "$KUBE" -n nagare-system get secret nagare-en-api-keys -o jsonpath='{.data.read-write}' | base64 -d)"
# The harness route check opens its own en forward on 18082; this one is the drill's.
kubectl --context "$KUBE" -n nagare-system port-forward svc/en 18083:80 >/dev/null 2>&1 &
EN_PF=$!
trap 'kill $EN_PF 2>/dev/null || true; [ -n "${KOURIER_PF:-}" ] && kill $KOURIER_PF 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do nc -z 127.0.0.1 18083 2>/dev/null && break; sleep 1; done
curl -sS -H "Authorization: Bearer $apiKey" http://127.0.0.1:18083/v1/schema > "$EV/en-schema.json"
unset apiKey
python3 -I - "$EV/en-schema.json" "$REPO/cluster/bootstrap/en/configmap.yaml" <<'PY'
import json, sys
served = json.load(open(sys.argv[1]))
assert "group" in served["source"] and "group#member" in served["source"], served["source"]
print("schema hash", served["hash"], "origin", served.get("origin"))
PY
kubectl --context "$KUBE" -n nagare-system get deploy en -o jsonpath='{.spec.template.metadata.annotations.nagare\.dev/en-schema-digest}' > "$EV/en-schema-digest.txt"
{
  printf 'en\t%s\n' "$(kubectl --context "$KUBE" -n nagare-system get deploy en -o jsonpath='{.spec.template.spec.containers[0].image}')"
  printf 'shomei\t%s\n' "$(kubectl --context "$KUBE" -n nagare-system get deploy shomei -o jsonpath='{.spec.template.spec.containers[0].image}')"
  printf 'nagare-access\t%s\n' "$(kubectl --context "$KUBE" -n nagare-system get ksvc nagare-access -o jsonpath='{.spec.template.spec.containers[0].image}')"
} > "$EV/images.tsv"
log "auth plane: $(tr '\n' ' ' < "$EV/images.tsv")"
if [ "$BOOTSTRAP_ONLY" = 1 ]; then
  log "bootstrap converged; stopping as NAGARE_DRILL_BOOTSTRAP_ONLY=1 asks"
  exit 0
fi

# --- 6. the example's image, packaged by `site package`, published under review ---
eval "$(N context env)"
destination="$NAGARE_REGISTRY_HOST/$CLOUDSDK_CORE_PROJECT/$NAGARE_ARTIFACT_REGISTRY_ID/$SITE"
# The published output is a copy of the example's, so a second release can differ from the first.
PUBLIC="$ROOT/site/public"
cp -R "$EXAMPLE/public/." "$PUBLIC/"
publish() { # tag key
  local out
  N site package -f "$EXAMPLE/nagare/Config.hs" -C "$EXAMPLE" --ghc-env "$NAGARE_DRILL_GHC_ENV" --output-dir "$PUBLIC" \
    --archive "$ROOT/site/$1.tar" --tag "$1" > "$ROOT/site/$1.package"
  grep -qx "image: $destination:$1" "$ROOT/site/$1.package" || { echo "site package derived another image than $destination:$1" >&2; exit 1; }
  out="$(N app image-plan --archive "$ROOT/site/$1.tar" --destination "$destination:$1" --key "$2" --save-plan "$ROOT/reviews/image-$1")"
  review_apply "$ROOT/reviews/image-$1"
  printf '%s\n' "$out" | sed -n 's/^Image resource: //p' | tail -1
}
IMAGE_A="$(publish "$TAG" "$SITE")"
[ -n "$IMAGE_A" ] || { echo "image review named no resource" >&2; exit 1; }
log "published $destination:$TAG as $IMAGE_A"

# --- 7. the protected site, its preview, and a second release to roll back from ---
site() { N site "$@" -f "$EXAMPLE/nagare/Config.hs" --ghc-env "$NAGARE_DRILL_GHC_ENV"; }
deploy() { site deploy -C "$EXAMPLE" --skip-build "$@"; }
deploy --tag "$TAG" --image-resource "$IMAGE_A" > "$EV/site-deploy.log" 2>&1 || { tail -5 "$EV/site-deploy.log" >&2; exit 1; }
IMAGE_A_REF="$(kubectl --context "$KUBE" -n "$NS" get ksvc "$SITE" -o jsonpath='{.spec.template.spec.containers[0].image}')"
log "deployed $HOST from $IMAGE_A_REF"
# A static preview needs the site's four accepted environment stores: one reviewed key
# in each of the Runtime and Preview ConfigMaps and Secrets.
store() { # label args...
  local label="$1"; shift
  N "$@" -f "$EXAMPLE/nagare/Config.hs" --save-plan "$ROOT/reviews/store-$label" > /dev/null
  review_apply "$ROOT/reviews/store-$label"
  python3 -I -c 'import json,sys; print(sorted({r for o in json.load(open(sys.argv[1]))["operations"] for r in o["operation"].get("resources", [])})[0])' "$ROOT/reviews/store-$label/review.json"
}
( cd "$EXAMPLE"
  STORES=(
    "$(store runtime-env env set "$SITE" DRILL_RUNTIME one --runtime)"
    "$(printf 'runtime-secret\n' | store runtime-secret secret set "$SITE" DRILL_RUNTIME_SECRET --runtime --version v1)"
    "$(store preview-env env set "$SITE" DRILL_PREVIEW one --preview)"
    "$(printf 'preview-secret\n' | store preview-secret secret set "$SITE" DRILL_PREVIEW_SECRET --preview --version v1)"
  )
  printf '%s\n' "${STORES[@]}" > "$EV/stores.txt"
)
mapfile -t STORES < "$EV/stores.txt"
[ "${#STORES[@]}" = 4 ] || { echo "expected four environment stores, got: ${STORES[*]}" >&2; exit 1; }
site preview deploy --name "$PREVIEW" -C "$EXAMPLE" --skip-build --tag "$TAG" --image-resource "$IMAGE_A" \
  --preview-env-resource "${STORES[0]}" --preview-env-resource "${STORES[1]}" --preview-env-resource "${STORES[2]}" --preview-env-resource "${STORES[3]}" \
  --save-plan "$ROOT/reviews/preview" > "$EV/preview-plan.log" 2>&1 || { tail -5 "$EV/preview-plan.log" >&2; exit 1; }
review_apply "$ROOT/reviews/preview"
log "deployed preview $PREVIEW_HOST"
# Each enforcer route answers over its local-CA certificate once cert-manager has issued it.
kubectl --context "$KUBE" -n cert-manager get secret nagare-local-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "$ROOT/ca.pem"
kubectl --context "$KUBE" -n kourier-system port-forward svc/kourier "$INGRESS_PORT:443" "$INGRESS_HTTP_PORT:80" >/dev/null 2>&1 &
KOURIER_PF=$!
for _ in $(seq 1 30); do nc -z 127.0.0.1 "$INGRESS_PORT" 2>/dev/null && break; sleep 1; done
get() { # host path [curl args...]
  local host="$1" path="$2"; shift 2
  curl -sS -o "$ROOT/body" -w '%{http_code}' --max-time 20 --cacert "$ROOT/ca.pem" --connect-to "$host:443:127.0.0.1:$INGRESS_PORT" "$@" "https://$host$path" 2>/dev/null || true
}
await_route() { # host
  local n
  for n in $(seq 1 600); do
    if [ "$(get "$1" "/")" = 302 ]; then record "seconds until $1 answered 302" "$n"; return 0; fi
    sleep 1
  done
  echo "$1 did not answer 302 over the local CA within 600 s: last $(get "$1" "/")" >&2; exit 1
}
await_route "$HOST"; await_route "$PREVIEW_HOST"
expect "origin ksvc url" "$(kubectl --context "$KUBE" -n "$NS" get ksvc "$SITE" -o jsonpath='{.status.url}')" "http://$SITE.$NS.svc.cluster.local"
expect "origin visibility label" "$(kubectl --context "$KUBE" -n "$NS" get ksvc "$SITE" -o jsonpath='{.metadata.labels.networking\.knative\.dev/visibility}')" "cluster-local"
expect "enforcer route namespace" "$(kubectl --context "$KUBE" -n nagare-system get domainmapping "$HOST" -o jsonpath='{.spec.ref.name}')" "nagare-access"
expect "preview route namespace" "$(kubectl --context "$KUBE" -n nagare-system get domainmapping "$PREVIEW_HOST" -o jsonpath='{.spec.ref.name}')" "nagare-access"

# --- 8. the route check: anonymous, API, ungranted, team grant, stranger, removal, diagnostic ---
"$NAGARE_DRILL_HARNESS" route-check --context "$CTX" --kube-context "$KUBE" --host "$HOST" --ingress-port-forward "$HARNESS_INGRESS_PORT" \
  --expect-body "Protected static site" --nagarectl "$NAGARE_DRILL_NAGARECTL" --reviews "$ROOT/reviews" --team "$TEAM" --other-team "$OTHER" \
  2>&1 | tee "$EV/route-check.log"
grep -q "^route check: ok" "$EV/route-check.log" || { echo "route check failed" >&2; exit 1; }

# --- 9. a direct grant through the real login: the preview inherits the policy, never the grants;
#        the diagnostic observes a revoke before the cached session expires; origin bypass ---
secret="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
email="drill-$(printf '%s' "$secret" | tr 'A-Z' 'a-z' | head -c 10)@example.test"
password="Dr-$secret"
user="$(printf '%s\n' "$password" | kubectl --context "$KUBE" -n nagare-system exec -i deploy/shomei -- env LC_ALL=C.UTF-8 shomei-admin users create --email "$email" --display-name "site access drill" --email-verified | sed -n 's/^created user \(user_[A-Za-z0-9_-]*\).*/\1/p')"
[ -n "$user" ] || { echo "shomei-admin created no user" >&2; exit 1; }
unset secret
export NAGARE_EN_API_KEY="$(kubectl --context "$KUBE" -n nagare-system get secret nagare-en-api-keys -o jsonpath='{.data.read-write}' | base64 -d)"
check() { N access check --host "$1" --user "$2" --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["decision"])'; }
grant() { N access grant --host "$1" --user "$2" --save-plan "$ROOT/reviews/grant-$3" > /dev/null; review_apply "$ROOT/reviews/grant-$3"; }
revoke() { N access revoke --host "$1" --user "$2" --save-plan "$ROOT/reviews/revoke-$3" > /dev/null; review_apply "$ROOT/reviews/revoke-$3"; }
expect "anonymous preview document" "$(get "$PREVIEW_HOST" "/")" "302"
expect "anonymous preview API" "$(get "$PREVIEW_HOST" "/api" -H 'Accept: application/json')" "401"
expect "raw identity header, anonymous" "$(get "$HOST" "/api" -H 'Accept: application/json' -H "X-Forwarded-User: $user")" "401"
grant "$HOST" "$user" production
expect "check production after direct grant" "$(check "$HOST" "$user")" "allowed"
expect "check preview after production grant" "$(check "$PREVIEW_HOST" "$user")" "denied"
# The built-in login form: its CSRF cookie and hidden token, then the session cookies.
get "$HOST" "/_nagare/login?rd=%2F" -D "$ROOT/login-headers" > /dev/null
csrf="$(sed -n 's/^[Ss]et-[Cc]ookie: __Host-nagare_csrf=\([^;]*\).*/\1/p' "$ROOT/login-headers" | tail -1)"
token="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' "$ROOT/body" | head -1)"
[ -n "$csrf" ] && [ "$csrf" = "$token" ] || { echo "no matching CSRF cookie and form token" >&2; exit 1; }
expect "login" "$(get "$HOST" "/_nagare/login" -X POST -H "Cookie: __Host-nagare_csrf=$csrf" --data-urlencode "csrf=$token" --data-urlencode "rd=/" --data-urlencode "email=$email" --data-urlencode "password=$password" -D "$ROOT/session-headers")" "302"
unset password
session="$(sed -n 's/^[Ss]et-[Cc]ookie: nagare_session=\([^;]*\).*/\1/p' "$ROOT/session-headers" | tail -1)"
[ -n "$session" ] || { echo "login set no session cookie" >&2; exit 1; }
rm -f "$ROOT/login-headers" "$ROOT/session-headers"
granted() { get "$1" "${2:-/}" -H "Cookie: nagare_session=$session"; }
for _ in $(seq 1 60); do [ "$(granted "$HOST")" = 200 ] && break; sleep 1; done
expect "granted session on production" "$(granted "$HOST")" "200"
grep -q "Protected static site" "$ROOT/body" || { echo "the production page is not the example" >&2; exit 1; }
expect "granted session on the preview" "$(granted "$PREVIEW_HOST")" "403"
# The origin's cluster-local hostname is not an external route: the ingress has no backend for it.
expect "origin bypass through the ingress" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -H "Host: $SITE.$NS.svc.cluster.local" "http://127.0.0.1:$INGRESS_HTTP_PORT/")" "404"
revoke "$HOST" "$user" production
revokedAt=$(date +%s)
expect "check production right after revoke" "$(check "$HOST" "$user")" "denied"
record "session right after revoke (cached)" "$(granted "$HOST")"
for _ in $(seq 1 90); do [ "$(granted "$HOST")" = 403 ] && break; sleep 1; done
expect "session after the decision TTL" "$(granted "$HOST")" "403"
record "seconds from revoke to 403" "$(( $(date +%s) - revokedAt ))"

# --- 10. a second release with one more file, then a rollback that keeps the protection ---
printf 'second release\n' > "$PUBLIC/release.txt"
IMAGE_B="$(publish "$TAG-2" "$SITE-2")"
deploy --tag "$TAG-2" --image-resource "$IMAGE_B" > "$EV/site-deploy-2.log" 2>&1 || { tail -5 "$EV/site-deploy-2.log" >&2; exit 1; }
IMAGE_B_REF="$(kubectl --context "$KUBE" -n "$NS" get ksvc "$SITE" -o jsonpath='{.spec.template.spec.containers[0].image}')"
[ "$IMAGE_B_REF" != "$IMAGE_A_REF" ] || { echo "the second release runs the first image" >&2; exit 1; }
grant "$HOST" "$user" second
for _ in $(seq 1 90); do [ "$(granted "$HOST" /release.txt)" = 200 ] && break; sleep 1; done
expect "second release file on the second release" "$(granted "$HOST" /release.txt)" "200"
site releases > "$EV/releases.txt"
site rollback "$TAG" --image-resource "$IMAGE_A" --save-plan "$ROOT/reviews/rollback" > "$EV/rollback-plan.log" 2>&1 || { tail -5 "$EV/rollback-plan.log" >&2; exit 1; }
review_apply "$ROOT/reviews/rollback"
for _ in $(seq 1 90); do [ "$(granted "$HOST" /release.txt)" = 404 ] && break; sleep 1; done
expect "second release file absent after rollback" "$(granted "$HOST" /release.txt)" "404"
expect "granted session after rollback" "$(granted "$HOST")" "200"
expect "anonymous after rollback" "$(get "$HOST" "/")" "302"
expect "rolled back ksvc image is the first release" "$(kubectl --context "$KUBE" -n "$NS" get ksvc "$SITE" -o jsonpath='{.spec.template.spec.containers[0].image}')" "$IMAGE_A_REF"
revoke "$HOST" "$user" final
unset NAGARE_EN_API_KEY session
N inventory status --json > "$EV/inventory.json"

# --- the record ---
python3 -I - "$ROOT" "$CTX" "$candidate" "$TAG" "$HOST" "$PREVIEW_HOST" "$TEAM" "$OTHER" <<'PY'
import json, sys
root, context, candidate, tag, host, preview, team, other = sys.argv[1:]
ev = f"{root}/evidence"
rows = [line.rstrip("\n").split("\t", 1) for line in open(f"{ev}/observations.tsv")]
images = dict(line.rstrip("\n").split("\t", 1) for line in open(f"{ev}/images.tsv"))
schema = json.load(open(f"{ev}/en-schema.json"))
status = json.load(open(f"{ev}/inventory.json"))
record = {
    "schemaVersion": 1, "mode": "local", "context": context,
    "candidate": {k: json.loads(candidate).get(k) for k in ("version", "revision")},
    "imageTag": tag, "images": images,
    "enSchema": {"hash": schema["hash"], "origin": schema.get("origin"), "digestAnnotation": open(f"{ev}/en-schema-digest.txt").read().strip()},
    "hosts": {"production": host, "preview": preview}, "teams": {"granted": team, "other": other},
    "routeCheck": [line.rstrip("\n") for line in open(f"{ev}/route-check.log") if line.startswith("route")],
    "observations": [{"step": k, "value": v} for k, v in rows],
    "inventory": {key: status.get(key) for key in ("activeTransaction", "transactionStatus", "observationComplete")},
}
json.dump(record, open(f"{ev}/site-access-drill.json", "w"), indent=2, sort_keys=True)
PY
log "site access drill OK: record in $EV/site-access-drill.json"
