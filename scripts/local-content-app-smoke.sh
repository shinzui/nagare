#!/usr/bin/env bash
# scripts/local-content-app-smoke.sh (MasterPlan 39): cluster/examples/content-app on a disposable
# LOCAL context, with its three declarations, natively.
#
#   1. the bucket, the key set (a ten-minute period and five-minute overlap here) and the
#      whoami image are reviewed and applied; the app is deployed through a saved review;
#   2. EP-283 M4: each workload reads its bucket credential from its own Secret; the read-write
#      credential writes and reads back, the read-only one reads and its write is refused;
#   3. EP-285 M4: alpha., beta. and share. under the content domain answer from the gateway with
#      their own Host header under the local CA's wildcard certificate;
#   4. EP-286 M4: a token signed with the active key verifies against the public file the
#      verifier's pod has mounted; across a promotion, with the verifier's pod restarted, the old
#      token still verifies during the overlap and is refused after it; keyset status shows the
#      rotation.
#
# Usage, from the context's own environment (XDG_*, KUBECONFIG, DOCKER_HOST, the registry forward):
#   NAGARE_SMOKE_CONTEXT=NAME [NAGARECTL=…] [OPENSSL=openssl 3] scripts/local-content-app-smoke.sh
# The context must list the content domain the example routes (NAGARE_CONTENT_DOMAINS). Reviews and
# evidence go under NAGARE_SMOKE_ROOT (default $XDG_STATE_HOME/nagare/content-app-smoke/NAME); an
# applied review is not planned again, so a rerun continues.
set -euo pipefail

CTX="${NAGARE_SMOKE_CONTEXT:?name a mode=local context in NAGARE_SMOKE_CONTEXT}"
NAGARECTL="${NAGARECTL:-$(command -v nagarectl)}"
OPENSSL="${OPENSSL:-openssl}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$REPO/cluster/examples/content-app/nagare"
ROOT="${NAGARE_SMOKE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/nagare/content-app-smoke/$CTX}"
NS=personal
mkdir -p "$ROOT/reviews" "$ROOT/evidence" "$ROOT/work"

log() { printf '%s content-app smoke: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "content-app smoke: FAIL: $*" >&2; exit 1; }
N() { "$NAGARECTL" --context "$CTX" "$@"; }

P0="$PATH"; eval "$(N context env)"; export PATH="$P0"
[ "$NAGARE_MODE" = local ] || fail "context $CTX is not mode=local"
DOMAIN="${NAGARE_CONTENT_DOMAINS%%,*}"
[ -n "$DOMAIN" ] || fail "context $CTX lists no content domain"
"$OPENSSL" version | grep -q '^OpenSSL 3' || fail "OPENSSL must be OpenSSL 3, for raw Ed25519"
log "context $CTX; content domain $DOMAIN; root $ROOT"

# A saved review, applied once per run: plan with "$@" into reviews/NAME, apply, mark it applied.
reviewed() {
  local name="$1"; shift
  local dir="$ROOT/reviews/$name"
  if [ -e "$dir.applied" ]; then log "$name: applied earlier"; return 0; fi
  rm -rf "$dir"
  "$@" --save-plan "$dir" > "$dir.plan.log" 2>&1 || { tail -n 15 "$dir.plan.log" >&2; fail "$name: plan refused"; }
  log "$name: $(jq '.operations|length' "$dir/review.json") operations"
  N inventory apply "$dir" --yes > "$dir.apply.log" 2>&1 || { tail -n 15 "$dir.apply.log" >&2; fail "$name: apply did not converge"; }
  touch "$dir.applied"
}

# --- 1. bucket, key set, image, app ---------------------------------------------------------
sed -e 's/mkMinutes (24 \* 60)/mkMinutes 10/' -e 's/mkMinutes 120/mkMinutes 5/' "$EXAMPLE/KeySets.hs" > "$ROOT/work/KeySets.hs"
grep -q 'mkMinutes 10' "$ROOT/work/KeySets.hs" && grep -q 'mkMinutes 5' "$ROOT/work/KeySets.hs" || fail "could not shorten the key set's period"
reviewed bucket N bucket plan --file "$EXAMPLE/Buckets.hs"
reviewed keyset N keyset plan --file "$ROOT/work/KeySets.hs"
dest="$NAGARE_REGISTRY_HOST/$CLOUDSDK_CORE_PROJECT/$NAGARE_ARTIFACT_REGISTRY_ID/whoami:v1.11.0"
archive="$ROOT/work/whoami-v1.11.0.tar"
if [ ! -e "$archive" ]; then
  docker pull --platform "$NAGARE_TARGET_PLATFORM" docker.io/traefik/whoami:v1.11.0 > /dev/null
  docker save --platform "$NAGARE_TARGET_PLATFORM" -o "$archive" docker.io/traefik/whoami:v1.11.0
fi
reviewed image N app image-plan --archive "$archive" --destination "$dest" --key content-app-whoami
resource="$(sed -n 's/^Image resource: //p' "$ROOT/reviews/image.plan.log" | tail -1)"
[ -n "$resource" ] || fail "the image review named no resource"
reviewed app env CONTENT_APP_IMAGE="${dest%:*}" "$NAGARECTL" --context "$CTX" app deploy -f "$EXAMPLE/Config.hs" --tag v1.11.0 --image-resource "$resource"
kubectl -n "$NS" get ksvc content-app -o jsonpath='{.status.url}{" ready="}{.status.conditions[?(@.type=="Ready")].status}{"\n"}' | tee "$ROOT/evidence/app.txt"
kubectl -n "$NS" rollout status deployment/content-gateway --timeout=180s > /dev/null || fail "the gateway is not available"

# A one-shot pod in the namespace; prints its log and returns its exit code.
oneshot() {
  local name="$1" overrides="$2"
  kubectl -n "$NS" delete pod "$name" --ignore-not-found --wait=true > /dev/null
  kubectl -n "$NS" run "$name" --restart=Never --image=busybox --overrides="$overrides" > /dev/null
  kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$name" --timeout=180s > /dev/null 2>&1 \
    || kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Failed pod/"$name" --timeout=5s > /dev/null 2>&1 || true
  kubectl -n "$NS" logs "$name" 2>&1
  local phase; phase="$(kubectl -n "$NS" get pod "$name" -o jsonpath='{.status.phase}')"
  kubectl -n "$NS" delete pod "$name" --wait=false > /dev/null
  [ "$phase" = Succeeded ]
}

# --- 2. EP-283 M4: each workload's own bucket credential ------------------------------------
log "step 2: bucket access"
for w in content-app content-gateway; do
  kind=ksvc; [ "$w" = content-gateway ] && kind=deployment
  printf '%s reads its key from: %s\n' "$w" "$(kubectl -n "$NS" get "$kind" "$w" -o json | jq -r '[.. | objects | select(.name? == "NAGARE_BUCKET_PUBLICATIONS_SECRET_ACCESS_KEY") | .valueFrom.secretKeyRef.name] | unique | join(",")')"
done | tee "$ROOT/evidence/bucket-secrets.txt"
grep -q '^content-app reads its key from: nagare-bucket-publications-content-app$' "$ROOT/evidence/bucket-secrets.txt" || fail "the service does not read its own credential"
grep -q '^content-gateway reads its key from: nagare-bucket-publications-content-gateway$' "$ROOT/evidence/bucket-secrets.txt" || fail "the gateway does not read its own credential"
mc_pod() { # secret, script
  jq -cn --arg image "$NAGARE_LOCAL_MC_IMAGE" --arg secret "$1" --arg script "$2" --arg endpoint "http://minio.nagare-system.svc.cluster.local:9000" '{spec:{restartPolicy:"Never",containers:[{name:"mc",image:$image,command:["/bin/sh","-c",$script],env:[{name:"HOME",value:"/tmp"},{name:"MC_CONFIG_DIR",value:"/tmp/.mc"},{name:"ENDPOINT",value:$endpoint},{name:"AWS_ACCESS_KEY_ID",valueFrom:{secretKeyRef:{name:$secret,key:"AWS_ACCESS_KEY_ID"}}},{name:"AWS_SECRET_ACCESS_KEY",valueFrom:{secretKeyRef:{name:$secret,key:"AWS_SECRET_ACCESS_KEY"}}}]}]}}'
}
alias_cmd='mc alias set s "$ENDPOINT" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" >/dev/null'
stamp="smoke $(date -u +%Y%m%dT%H%M%SZ)"
oneshot mc-rw "$(mc_pod nagare-bucket-publications-content-app "$alias_cmd && echo '$stamp' | mc pipe s/nagare-app-publications/smoke/object.txt >/dev/null && echo wrote && mc cat s/nagare-app-publications/smoke/object.txt")" | tee "$ROOT/evidence/bucket-rw.txt" || fail "the read-write credential could not write and read back"
grep -qx "$stamp" "$ROOT/evidence/bucket-rw.txt" || fail "the read-write credential read back something else"
oneshot mc-ro "$(mc_pod nagare-bucket-publications-content-gateway "$alias_cmd && mc cat s/nagare-app-publications/smoke/object.txt && if echo x | mc pipe s/nagare-app-publications/smoke/forbidden.txt 2>/tmp/err; then echo WRITE-ALLOWED; exit 1; else echo write refused: \$(cat /tmp/err | head -c 160); fi")" | tee "$ROOT/evidence/bucket-ro.txt" || fail "the read-only credential could write, or could not read"
grep -qx "$stamp" "$ROOT/evidence/bucket-ro.txt" && grep -q 'write refused: .*Insufficient permissions' "$ROOT/evidence/bucket-ro.txt" || fail "the read-only check did not read and refuse"
log "step 2 ok: read-write writes, read-only reads and is refused a write"

# --- 3. EP-285 M4: each host with its own Host header ----------------------------------------
log "step 3: content hosts"
kubectl -n "$NS" wait --for=condition=Ready certificate/nagare-content-content-gateway --timeout=300s > /dev/null || fail "the content certificate is not Ready"
ca="$(kubectl -n "$NS" get secret nagare-content-content-gateway -o jsonpath='{.data.ca\.crt}')"
[ -n "$ca" ] || fail "the content certificate's Secret has no ca.crt"
kourier="$(kubectl -n kourier-system get svc kourier -o jsonpath='{.spec.clusterIP}')"
script="echo \"\$CA\" | base64 -d > /tmp/ca.crt; for h in alpha.$DOMAIN beta.$DOMAIN share.$DOMAIN; do printf '%s -> ' \$h; curl -sS --max-time 15 --cacert /tmp/ca.crt --resolve \$h:443:$kourier https://\$h/ | grep -i '^Host:' || echo FAILED; done; curl -sS -o /dev/null -w 'http: %{http_code} %{redirect_url}\n' --resolve alpha.$DOMAIN:80:$kourier http://alpha.$DOMAIN/"
oneshot hosts "$(jq -cn --arg ca "$ca" --arg script "$script" '{spec:{restartPolicy:"Never",containers:[{name:"curl",image:"alpine/curl",command:["/bin/sh","-c",$script],env:[{name:"CA",value:$ca}]}]}}')" | tee "$ROOT/evidence/content-hosts.txt" || true
for h in alpha beta share; do grep -qi "^$h.$DOMAIN -> Host: $h.$DOMAIN" "$ROOT/evidence/content-hosts.txt" || fail "$h.$DOMAIN did not answer with its own Host"; done
# Each request above verified the served certificate for its host under the local CA (--cacert);
# the certificate cert-manager issued covers the wildcard and the apex.
kubectl -n "$NS" get secret nagare-content-content-gateway -o jsonpath='{.data.tls\.crt}' | base64 -d | "$OPENSSL" x509 -noout -subject -issuer -ext subjectAltName | tee -a "$ROOT/evidence/content-hosts.txt"
grep -q "DNS:\*.$DOMAIN" "$ROOT/evidence/content-hosts.txt" || fail "the served certificate does not cover *.$DOMAIN"
log "step 3 ok: three hosts, each with its own Host header, under the wildcard certificate"

# --- 4. EP-286 M4: signing across a rotation ------------------------------------------------
log "step 4: key set rotation"
b64url() { tr '_-' '/+' | awk '{ l = length($0) % 4; if (l == 2) $0 = $0 "=="; else if (l == 3) $0 = $0 "="; print }' | base64 -d; }
# The private file, as the signer reads it (the Secret the signer's projected volume holds).
private_file() { kubectl -n "$NS" get secret nagare-keyset-view-grants -o jsonpath='{.data.private\.json}' | base64 -d; }
# The public file as the verifier's running pod has it mounted, read from inside that pod.
verifier_file() {
  local pod; pod="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=content-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [ -n "$pod" ] || pod="$(kubectl -n "$NS" get pods -o name | grep -m1 content-gateway | cut -d/ -f2)"
  kubectl -n "$NS" debug "pod/$pod" -q -i --image=busybox --target=content-gateway --profile=general -- cat /proc/1/root/var/run/nagare/keysets/view-grants/public.json 2>/dev/null | tail -n 1
}
# sign: prints "kid.message.signature" with the active key of the private file.
sign() {
  local w; w="$(mktemp -d "$ROOT/work/sign.XXXXXX")"; local file; file="$(private_file)"
  local kid; kid="$(printf '%s' "$file" | jq -r '.keys[] | select(.status=="active") | .kid')"
  { printf '302e020100300506032b657004220420' | xxd -r -p; printf '%s' "$file" | jq -r '.keys[] | select(.status=="active") | .d' | b64url; } > "$w/k.der"
  "$OPENSSL" pkey -inform DER -in "$w/k.der" -out "$w/k.pem" 2>/dev/null
  printf '%s.%s' "$kid" "$1" > "$w/m"
  "$OPENSSL" pkeyutl -sign -rawin -inkey "$w/k.pem" -in "$w/m" -out "$w/s"
  printf '%s.%s.%s\n' "$kid" "$1" "$(base64 < "$w/s" | tr -d '\n')"; rm -rf "$w"
}
# verify TOKEN PUBLIC-FILE: accepts the token when its kid is published and the signature holds.
verify() {
  local w; w="$(mktemp -d "$ROOT/work/verify.XXXXXX")"
  local kid="${1%%.*}" rest="${1#*.}"; local message="${rest%%.*}" signature="${rest#*.}"
  local x; x="$(printf '%s' "$2" | jq -r --arg kid "$kid" '.keys[] | select(.kid==$kid) | .x')"
  if [ -z "$x" ]; then echo "refused: $kid is not published"; rm -rf "$w"; return 1; fi
  { printf '302a300506032b6570032100' | xxd -r -p; printf '%s' "$x" | b64url; } > "$w/p.der"
  "$OPENSSL" pkey -pubin -inform DER -in "$w/p.der" -out "$w/p.pem" 2>/dev/null
  printf '%s.%s' "$kid" "$message" > "$w/m"; printf '%s' "$signature" | base64 -d > "$w/s"
  if "$OPENSSL" pkeyutl -verify -rawin -pubin -inkey "$w/p.pem" -in "$w/m" -sigfile "$w/s" > /dev/null 2>&1; then echo "ok: $kid"; rm -rf "$w"; return 0; fi
  echo "refused: bad signature under $kid"; rm -rf "$w"; return 1
}
active() { private_file | jq -r '.keys[] | select(.status=="active") | .kid'; }
until_kid() { # JQ-PREDICATE SECONDS: wait until the verifier's mounted file satisfies the predicate
  local deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do verifier_file | jq -e "$1" > /dev/null 2>&1 && return 0; sleep 20; done
  return 1
}
{
  N keyset status view-grants
  K1="$(active)"; T1="$(sign first)"; echo "signed T1 with $K1"
  echo "T1 against the verifier's mounted file: $(verify "$T1" "$(verifier_file)")"
  echo "waiting for the promotion (a ten-minute period, a five-minute rotator)"
  deadline=$(( $(date +%s) + 1500 )); while [ "$(active)" = "$K1" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 30; done
  K2="$(active)"; [ "$K2" != "$K1" ] || { echo "no promotion within 25 minutes"; exit 1; }
  echo "promoted: $K2 active, $K1 previous; restarting the verifier and the signer mid-rotation"
  kubectl -n "$NS" rollout restart deployment/content-gateway > /dev/null && kubectl -n "$NS" rollout status deployment/content-gateway --timeout=180s > /dev/null
  kubectl -n "$NS" delete pod -l serving.knative.dev/service=content-app --ignore-not-found --wait=false > /dev/null
  until_kid "[.keys[] | select(.status==\"active\") | .kid] == [\"$K2\"]" 240 || { echo "the verifier's mounted file never showed $K2 active"; exit 1; }
  T2="$(sign second)"; echo "signed T2 with $K2"
  echo "T2 against the restarted verifier's file: $(verify "$T2" "$(verifier_file)")"
  echo "T1 during the overlap: $(verify "$T1" "$(verifier_file)")"
  N keyset status view-grants
  echo "waiting for the overlap to pass and the rotator to withdraw $K1"
  until_kid "[.keys[].kid] | index(\"$K1\") | not" 1200 || { echo "$K1 was never withdrawn from the verifier's file"; exit 1; }
  echo "T1 after the overlap: $(verify "$T1" "$(verifier_file)" || true)"
  echo "T2 after the overlap: $(verify "$T2" "$(verifier_file)")"
  N keyset status view-grants
} 2>&1 | tee "$ROOT/evidence/rotation.txt"
grep -q '^T1 against the verifier.s mounted file: ok' "$ROOT/evidence/rotation.txt" || fail "T1 did not verify before the rotation"
grep -q '^T2 against the restarted verifier.s file: ok' "$ROOT/evidence/rotation.txt" || fail "T2 did not verify after the restart"
grep -q '^T1 during the overlap: ok' "$ROOT/evidence/rotation.txt" || fail "T1 did not verify during the overlap"
grep -q '^T1 after the overlap: refused' "$ROOT/evidence/rotation.txt" || fail "T1 still verified after the overlap"
grep -q '^T2 after the overlap: ok' "$ROOT/evidence/rotation.txt" || fail "T2 stopped verifying"
log "step 4 ok: the overlap is honoured across a rotation and a restart"
log "content-app smoke: PASS"
