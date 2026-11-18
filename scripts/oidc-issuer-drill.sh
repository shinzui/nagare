#!/usr/bin/env bash
# EP-264 M3: Shomei as an OIDC provider on a disposable local context. It continues in a
# root that `NAGARE_DRILL_BOOTSTRAP_ONLY=1 scripts/site-access-drill.sh` bootstrapped from
# this tree: deploy the reference auth portal and the protected static site, sign a user in through
# the portal and keep the cookie jar, then set NAGARE_AUTH_ISSUER, review and apply the
# issuer move, and check discovery, the anonymous redirect to /login, a signed-in
# authorization to a loopback redirect, the code exchange, the signature against the public
# key set, a service-account token, what is not served, the old session and token, and
# whether a Pod in `personal` reaches the public key set. Every step stops at its first
# refusal. The record is evidence/oidc-issuer-drill.tsv under the drill root; it names
# results, never a token or secret.
set -euo pipefail

: "${DOCKER_HOST:?the disposable Docker daemon socket the bootstrap used}"
: "${NAGARE_DRILL_NAGARECTL:?the candidate nagarectl}"
: "${NAGARE_DRILL_ROOT:?the root site-access-drill.sh bootstrapped}"
: "${NAGARE_DRILL_GHC_ENV:?the GHC package environment that resolves nagare-dsl}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$NAGARE_DRILL_ROOT"
CTX="${NAGARE_DRILL_CONTEXT:-site-access}"
BASE=127-0-0-1.sslip.io
PORTAL="auth.$BASE"
ISS="https://$PORTAL"
HELLO="protected-static-site.personal.$BASE"
REDIRECT=http://127.0.0.1:18090/callback
INGRESS_PORT="${NAGARE_DRILL_INGRESS_PORT:-18443}"
FORWARD_PORT="${NAGARE_DRILL_FORWARD_PORT:-15213}"
STAGES_MAX=6
DRILL_TAG="oidc-drill-$(date -u +%Y%m%d%H%M%S)"

for v in $(env | sed -n "s/^\(NAGARE_[A-Z_]*\|CLOUDSDK_[A-Z_]*\|PULUMI_[A-Z_]*\|KUBECONFIG\|SOPS_AGE_KEY_FILE\)=.*/\1/p"); do
  case "$v" in NAGARE_DRILL_*) ;; *) unset "$v" ;; esac
done
export XDG_CONFIG_HOME="$ROOT/config" XDG_STATE_HOME="$ROOT/state" XDG_CACHE_HOME="$ROOT/cache"
export SOPS_AGE_KEY_FILE="$ROOT/sops/age/keys.txt"
[ -f "$ROOT/images.env" ] || { echo "$ROOT has no images.env; bootstrap it with site-access-drill.sh first" >&2; exit 1; }
set -a; . "$ROOT/images.env"; set +a
export NAGARE_LOCAL_REGISTRY_FORWARD="127.0.0.1:$FORWARD_PORT"
export KUBECONFIG="$XDG_CONFIG_HOME/nagare/kubeconfigs/$CTX.yaml"
KUBE="$(kubectl config current-context)"
EV="$ROOT/evidence"
REVIEWS="$ROOT/reviews/$DRILL_TAG"
mkdir -p "$EV" "$REVIEWS" "$ROOT/oidc"
W="$ROOT/oidc"
log() { printf '%s oidc-drill: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
N() { "$NAGARE_DRILL_NAGARECTL" --context "$CTX" "$@"; }
record() { printf '%s\t%s\n' "$1" "$2" >> "$EV/oidc-issuer-drill.tsv"; log "$1: $2"; }
expect() { # label got wanted
  [ "$2" = "$3" ] || { echo "oidc-drill: $1: got $2, wanted $3" >&2; exit 1; }
  record "$1" "$2"
}
operations() { python3 -I -c 'import json,sys; ops=json.load(open(sys.argv[1]))["operations"]; print(sum(1 for o in ops if (o.get("operation", o).get("action") or {}).get("tag") != "VerifyResource"))' "$1/review.json"; }
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
platform_converge() { # label
  local n review ops
  for n in $(seq 1 "$STAGES_MAX"); do
    review="$REVIEWS/$1-$n"
    N platform bootstrap plan --out "$review" > "$review.plan.log" 2>&1 || { echo "platform plan $1-$n refused: $(tail -3 "$review.plan.log")" >&2; exit 1; }
    ops="$(operations "$review")"
    log "platform $1 stage $n: $ops operations"
    [ "$ops" != 0 ] || return 0
    N platform bootstrap apply "$review" --yes > "$review.apply.log" 2>&1 || resume_ambiguous "$review.apply.log" || { echo "platform apply $1-$n failed: $(tail -3 "$review.apply.log")" >&2; exit 1; }
  done
  echo "platform $1 did not converge in $STAGES_MAX stages" >&2; exit 1
}
wait_auth_plane() {
  kubectl --context "$KUBE" -n nagare-system rollout status deploy/shomei --timeout=300s >/dev/null
  kubectl --context "$KUBE" -n nagare-system wait ksvc/nagare-access --for=condition=Ready --timeout=300s >/dev/null
}

# --- 1. the local CA and the ingress on a loopback port ---
kubectl --context "$KUBE" -n cert-manager get secret nagare-local-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "$ROOT/ca.pem"
[ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$INGRESS_PORT/" -k)" = 000 ] || { echo "127.0.0.1:$INGRESS_PORT is in use; set NAGARE_DRILL_INGRESS_PORT" >&2; exit 1; }
kubectl --context "$KUBE" -n kourier-system port-forward svc/kourier "$INGRESS_PORT:443" >/dev/null 2>&1 &
KOURIER_PF=$!
trap 'kill $KOURIER_PF 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do nc -z 127.0.0.1 "$INGRESS_PORT" 2>/dev/null && break; sleep 1; done
# curl over the local CA to a public name; the body lands in $W/body, the headers in $W/headers.
get() { # host path [curl args...]
  local host="$1" path="$2"; shift 2
  curl -sS -o "$W/body" -D "$W/headers" -w '%{http_code}' --max-time 20 --cacert "$ROOT/ca.pem" --connect-to "$host:443:127.0.0.1:$INGRESS_PORT" "$@" "https://$host$path" 2>/dev/null || true
}
location() { sed -n 's/^[Ll]ocation: \(.*\)\r$/\1/p' "$W/headers" | tail -1; }
query() { python3 -I -c 'import sys, urllib.parse as u; q=u.parse_qs(u.urlsplit(sys.argv[1]).query); print(q.get(sys.argv[2], [""])[0])' "$1" "$2"; }

# --- 1b. a context left with the issuer by an earlier run moves back first, under review ---
profile="$XDG_CONFIG_HOME/nagare/contexts/$CTX.env"
if grep -q '^export NAGARE_AUTH_ISSUER=' "$profile"; then
  grep -v '^export NAGARE_AUTH_ISSUER=' "$profile" > "$profile.new" && mv "$profile.new" "$profile"
  platform_converge move-back
  wait_auth_plane
  expect "issuer after moving back" "$(kubectl --context "$KUBE" -n nagare-system get deploy shomei -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SHOMEI_ISSUER")].value}')" "nagare-shomei"
  expect "OIDC after moving back" "$(kubectl --context "$KUBE" -n nagare-system get deploy shomei -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SHOMEI_OIDC_ENABLED")].value}')" ""
fi

# --- 2. the reference portal and a protected site, each published and deployed under review ---
# The examples' Configs read the base domain from the environment, as the site drill does.
eval "$(N context env)"
publish_archive() { # archive destination key -> image resource
  local out
  out="$(N app image-plan --archive "$1" --destination "$2" --key "$3" --save-plan "$REVIEWS/image-$3")"
  review_apply "$REVIEWS/image-$3"
  printf '%s\n' "$out" | sed -n 's/^Image resource: //p' | tail -1
}
if ! N access portal show 2>/dev/null | grep -q "portal: $PORTAL "; then
  portalImage="$NAGARE_REGISTRY_PREFIX/auth-portal:$DRILL_TAG"
  docker build --platform linux/arm64 -t "$portalImage" "$REPO/cluster/examples/auth-portal" > "$W/portal-build.log" 2>&1 || { tail -5 "$W/portal-build.log" >&2; exit 1; }
  docker save "$portalImage" -o "$W/auth-portal-$DRILL_TAG.tar"
  portalResource="$(publish_archive "$W/auth-portal-$DRILL_TAG.tar" "$portalImage" "auth-portal-$DRILL_TAG")"
  [ -n "$portalResource" ] || { echo "the portal image review named no resource" >&2; exit 1; }
  (cd "$REPO/cluster/examples/auth-portal" && N deploy -f nagare/Config.hs --tag "$DRILL_TAG" --image-resource "$portalResource" --base-domain "$BASE" --ghc-env "$NAGARE_DRILL_GHC_ENV" --save-plan "$REVIEWS/portal") > "$W/portal-plan.log" 2>&1 || { tail -5 "$W/portal-plan.log" >&2; exit 1; }
  review_apply "$REVIEWS/portal"
  N access portal sync --save-plan "$REVIEWS/portal-sync" > "$W/portal-sync.log" 2>&1 || { tail -5 "$W/portal-sync.log" >&2; exit 1; }
  review_apply "$REVIEWS/portal-sync"
  record "portal deployed" "$PORTAL"
fi
SITE=protected-static-site
SITE_DIR="$REPO/cluster/examples/$SITE"
mkdir -p "$W/site/public"
cp -R "$SITE_DIR/public/." "$W/site/public/"
siteImage="$NAGARE_REGISTRY_PREFIX/$SITE:$DRILL_TAG"
N site package -f "$SITE_DIR/nagare/Config.hs" -C "$SITE_DIR" --ghc-env "$NAGARE_DRILL_GHC_ENV" --output-dir "$W/site/public" \
  --archive "$W/site-$DRILL_TAG.tar" --tag "$DRILL_TAG" > "$W/site-package.log" 2>&1 || { tail -5 "$W/site-package.log" >&2; exit 1; }
grep -qx "image: $siteImage" "$W/site-package.log" || { echo "site package derived another image than $siteImage" >&2; exit 1; }
siteResource="$(publish_archive "$W/site-$DRILL_TAG.tar" "$siteImage" "$SITE-$DRILL_TAG")"
[ -n "$siteResource" ] || { echo "the site image review named no resource" >&2; exit 1; }
N site deploy -f "$SITE_DIR/nagare/Config.hs" --ghc-env "$NAGARE_DRILL_GHC_ENV" -C "$SITE_DIR" --skip-build --tag "$DRILL_TAG" --image-resource "$siteResource" > "$W/site-deploy.log" 2>&1 || { tail -5 "$W/site-deploy.log" >&2; exit 1; }
record "protected site deployed" "$HELLO"
wait_auth_plane
for _ in $(seq 1 600); do [ "$(get "$PORTAL" /healthz)" = 200 ] && break; sleep 1; done
expect "portal healthz" "$(get "$PORTAL" /healthz)" "200"
for _ in $(seq 1 600); do [ "$(get "$HELLO" /)" = 302 ] && break; sleep 1; done
expect "anonymous protected-hello" "$(get "$HELLO" /)" "302"

# --- 3. a granted user signs in through the portal; the jar is kept ---
secret="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
email="oidc-$(printf '%s' "$secret" | tr 'A-Z' 'a-z' | head -c 10)@example.test"
password="Dr-$secret"
unset secret
user="$(printf '%s\n' "$password" | kubectl --context "$KUBE" -n nagare-system exec -i deploy/shomei -- env LC_ALL=C.UTF-8 shomei-admin users create --email "$email" --display-name "oidc drill" --email-verified | sed -n 's/^created user \(user_[A-Za-z0-9_-]*\).*/\1/p')"
[ -n "$user" ] || { echo "shomei-admin created no user" >&2; exit 1; }
export NAGARE_EN_API_KEY="$(kubectl --context "$KUBE" -n nagare-system get secret nagare-en-api-keys -o jsonpath='{.data.read-write}' | base64 -d)"
N access grant --host "$HELLO" --user "$user" --save-plan "$REVIEWS/grant" > /dev/null
review_apply "$REVIEWS/grant"
portal_sign_in() { # jar return_to -> prints the hand-off's status
  local jar="$1" returnTo="$2" csrf
  get "$PORTAL" "/login?return_to=$(python3 -I -c 'import sys, urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$returnTo")" -c "$jar" -b "$jar" -H 'Accept: text/html' > /dev/null
  csrf="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' "$W/body" | head -1)"
  [ -n "$csrf" ] || { echo "the portal login page has no CSRF token" >&2; exit 1; }
  python3 -I -c 'import html, re, sys; m = re.search(r"name=\"return_to\" value=\"([^\"]*)\"", open(sys.argv[1]).read()); sys.exit(0 if m and html.unescape(m.group(1)) == sys.argv[2] else 1)' "$W/body" "$returnTo" \
    || { echo "the portal's login form does not carry return_to unchanged" >&2; exit 1; }
  get "$PORTAL" /login -X POST -c "$jar" -b "$jar" -H 'Accept: text/html' --data-urlencode "csrf=$csrf" --data-urlencode "loginId=$email" \
    --data-urlencode "password=$password" --data-urlencode "return_to=$returnTo"
}
JAR="$W/jar"; rm -f "$JAR"
expect "portal sign-in hand-off" "$(portal_sign_in "$JAR" "https://$HELLO/")" "303"
expect "hand-off returns to" "$(location)" "https://$HELLO/"
for _ in $(seq 1 60); do [ "$(get "$HELLO" / -b "$JAR")" = 200 ] && break; sleep 1; done
expect "signed-in protected-hello before the move" "$(get "$HELLO" / -b "$JAR")" "200"
cp "$JAR" "$W/jar-before"
oldToken="$(awk '$6 == "nagare_session" {print $7}' "$JAR" | tail -1)"
[ -n "$oldToken" ] || { echo "the jar holds no session cookie" >&2; exit 1; }
expect "old access token as a bearer before the move" "$(get "$HELLO" / -H 'Accept: application/json' -H "Authorization: Bearer $oldToken")" "200"
expect "discovery before the move" "$(get "$PORTAL" /.well-known/openid-configuration)" "404"

# --- 4. the issuer move, reviewed ---
profile="$XDG_CONFIG_HOME/nagare/contexts/$CTX.env"
grep -v '^export NAGARE_AUTH_ISSUER=' "$profile" > "$profile.new" && mv "$profile.new" "$profile"
printf 'export NAGARE_AUTH_ISSUER=%s\n' "$ISS" >> "$profile"
N context env | grep -q "NAGARE_AUTH_ISSUER='$ISS'" || { echo "the context does not export the issuer" >&2; exit 1; }
review="$REVIEWS/issuer"
N platform bootstrap plan --out "$review" > "$review.plan.log" 2>&1 || { echo "the issuer plan refused: $(tail -3 "$review.plan.log")" >&2; exit 1; }
summary="$(python3 -I -c 'import json,sys; print("\n".join(o.get("summary","") for o in json.load(open(sys.argv[1]))["operations"]))' "$review/review.json" | grep 'Shomei issuer' || true)"
[ "$(printf '%s\n' "$summary" | grep -c "Shomei issuer $ISS with OIDC enabled: tokens minted under any other issuer are refused")" = 1 ] || { echo "the review does not name the issuer once: $summary" >&2; exit 1; }
record "review names the issuer" "1 operation"
record "issuer review operations" "$(operations "$review")"
N platform bootstrap apply "$review" --yes > "$review.apply.log" 2>&1 || resume_ambiguous "$review.apply.log" || { echo "the issuer apply failed: $(tail -3 "$review.apply.log")" >&2; exit 1; }
platform_converge after-issuer
wait_auth_plane
expect "Shomei issuer" "$(kubectl --context "$KUBE" -n nagare-system get deploy shomei -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SHOMEI_ISSUER")].value}')" "$ISS"
expect "enforcer issuer" "$(kubectl --context "$KUBE" -n nagare-system get ksvc nagare-access -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="NAGARE_ACCESS_SHOMEI_ISSUER")].value}')" "$ISS"

# --- 5. public discovery and the key set ---
for _ in $(seq 1 120); do [ "$(get "$PORTAL" /.well-known/openid-configuration)" = 200 ] && break; sleep 1; done
expect "discovery" "$(get "$PORTAL" /.well-known/openid-configuration)" "200"
expect "discovery document" "$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["issuer"], d["authorization_endpoint"], d["token_endpoint"], ",".join(d["code_challenge_methods_supported"]))' "$W/body")" \
  "$ISS $ISS/oauth/authorize $ISS/oauth/token S256"
expect "key set" "$(get "$PORTAL" /.well-known/jwks.json)" "200"
cp "$W/body" "$W/jwks.json"
expect "not served: admin users" "$(get "$PORTAL" /v1/admin/users)" "404"
expect "not served: metrics" "$(get "$PORTAL" /metrics)" "404"
expect "not served: userinfo" "$(get "$PORTAL" /oauth/userinfo)" "404"

# --- 6. the old token and the old session after the move ---
expect "old access token as a bearer after the move" "$(get "$HELLO" / -H 'Accept: application/json' -H "Authorization: Bearer $oldToken")" "401"
unset oldToken
cp "$W/jar-before" "$JAR"
status="$(get "$HELLO" / -b "$JAR" -c "$JAR")"
[ "$status" != 307 ] || status="$(get "$HELLO" / -b "$JAR" -c "$JAR")"
signIns=0
if [ "$status" = 302 ]; then
  signIns=1
  expect "portal sign-in after the move" "$(portal_sign_in "$JAR" "https://$HELLO/")" "303"
  status="$(get "$HELLO" / -b "$JAR" -c "$JAR")"
fi
expect "the old jar reaches protected-hello after the move" "$status" "200"
record "new sign-ins the old jar needed" "$signIns"

# --- 7. a public client and a service account ---
client="$(kubectl --context "$KUBE" -n nagare-system exec deploy/shomei -- env LC_ALL=C.UTF-8 shomei-admin oauth-clients create --display-name cli --type public --redirect-uri "$REDIRECT" --scope openid)"
clientId="$(printf '%s\n' "$client" | sed -n 's/^client_id:[[:space:]]*\(oauthclient_[A-Za-z0-9_-]*\).*/\1/p')"
[ -n "$clientId" ] || { echo "shomei-admin printed no public client id: $client" >&2; exit 1; }
printf '%s\n' "$client" | grep -q 'client_secret:[[:space:]]*(none' || { echo "the public client has a secret" >&2; exit 1; }
account="$(kubectl --context "$KUBE" -n nagare-system exec deploy/shomei -- env LC_ALL=C.UTF-8 shomei-admin service-accounts create --display-name publisher)"
accountId="$(printf '%s\n' "$account" | sed -n 's/^client_id:[[:space:]]*\(svcacct_[A-Za-z0-9_-]*\).*/\1/p')"
accountSecret="$(printf '%s\n' "$account" | sed -n 's/^client_secret:[[:space:]]*\([^ ]*\).*/\1/p')"
unset account
[ -n "$accountId" ] && [ -n "$accountSecret" ] || { echo "shomei-admin printed no service account" >&2; exit 1; }
record "registered" "public client and service account"

# --- 8. the authorization-code flow with PKCE ---
verifier="$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-43)"
challenge="$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | basenc --base64url | tr -d '=')"
authorize="/oauth/authorize?$(python3 -I -c 'import sys, urllib.parse as u; print(u.urlencode([("response_type","code"),("client_id",sys.argv[1]),("redirect_uri",sys.argv[2]),("scope","openid"),("state","s1"),("code_challenge",sys.argv[3]),("code_challenge_method","S256")]))' "$clientId" "$REDIRECT" "$challenge")"
expect "anonymous authorize" "$(get "$PORTAL" "$authorize")" "302"
loginAt="$(location)"
case "$loginAt" in "$ISS/login?return_to="*) record "anonymous authorize goes to" "$ISS/login?return_to=…" ;; *) echo "anonymous authorize went to $loginAt" >&2; exit 1 ;; esac
returnTo="$(query "$loginAt" return_to)"
case "$returnTo" in "$ISS/oauth/authorize?"*) ;; *) echo "return_to is $returnTo" >&2; exit 1 ;; esac
# The portal hands a new session back to the authorization request itself.
FLOW="$W/flow-jar"; rm -f "$FLOW"
expect "portal sign-in for the authorization" "$(portal_sign_in "$FLOW" "$returnTo")" "303"
expect "the hand-off returns to the authorization request" "$(location)" "$returnTo"
expect "signed-in authorize" "$(get "$PORTAL" "${returnTo#"$ISS"}" -b "$FLOW" -c "$FLOW")" "302"
callback="$(location)"
case "$callback" in "$REDIRECT?"*) ;; *) echo "the authorization went to $callback" >&2; exit 1 ;; esac
expect "callback state" "$(query "$callback" state)" "s1"
expect "callback iss" "$(query "$callback" iss)" "$ISS"
code="$(query "$callback" code)"
# The browser already signed in with the old jar authorizes as well.
expect "authorize with the moved session" "$(get "$PORTAL" "$authorize" -b "$JAR" -c "$JAR")" "302"
case "$(location)" in "$REDIRECT?"*) record "moved session authorizes" "loopback redirect" ;; *) echo "the moved session went to $(location)" >&2; exit 1 ;; esac
expect "code exchange" "$(get "$PORTAL" /oauth/token -d grant_type=authorization_code -d "client_id=$clientId" --data-urlencode "code=$code" -d "code_verifier=$verifier" --data-urlencode "redirect_uri=$REDIRECT")" "200"
accessToken="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$W/body")"
refreshToken="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["refresh_token"])' "$W/body")"
verify() { # token -> "verified typ iss aud sid?"
  node -e '
    const crypto = require("crypto"), fs = require("fs");
    const [token, jwksFile] = process.argv.slice(1);
    const [h, p, s] = token.split(".");
    const header = JSON.parse(Buffer.from(h, "base64url")), claims = JSON.parse(Buffer.from(p, "base64url"));
    const jwk = JSON.parse(fs.readFileSync(jwksFile)).keys.find(k => k.kid === header.kid);
    const ok = !!jwk && crypto.verify("sha256", Buffer.from(h + "." + p), { key: crypto.createPublicKey({ key: jwk, format: "jwk" }), dsaEncoding: "ieee-p1363" }, Buffer.from(s, "base64url"));
    console.log([ok ? "verified" : "unverified", header.typ, claims.iss, JSON.stringify(claims.aud), claims.sid ? "sid" : "no-sid"].join(" "));
  ' "$1" "$W/jwks.json"
}
expect "code-flow token against the public key set" "$(verify "$accessToken")" "verified at+jwt $ISS \"nagare-access\" sid"
expect "refresh" "$(get "$PORTAL" /oauth/token -d grant_type=refresh_token -d "client_id=$clientId" --data-urlencode "refresh_token=$refreshToken")" "200"
unset accessToken refreshToken code verifier

# --- 9. the service account's token ---
expect "client_credentials" "$(get "$PORTAL" /oauth/token -u "$accountId:$accountSecret" -d grant_type=client_credentials)" "200"
serviceToken="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$W/body")"
expect "service token against the public key set" "$(verify "$serviceToken" | cut -d' ' -f1-4)" "verified at+jwt $ISS \"nagare-access\""
unset serviceToken accountSecret

# --- 10. from a Pod in personal, the public key set ---
inCluster="$(kubectl --context "$KUBE" -n personal run "oidc-jwks-$$" --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 --command -- \
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$ISS/.well-known/jwks.json" 2>/dev/null || true)"
record "in-cluster public key set from personal" "${inCluster:-no answer}"
rm -f "$W/body" "$W/headers" "$JAR" "$FLOW" "$W/jar-before"
log "done; record $EV/oidc-issuer-drill.tsv"
