#!/usr/bin/env bash
# EP-191 M4: the native confirmation of `domains tls` on a disposable local context.
# scripts/site-access-drill.sh bootstraps the `site-access` context and deploys the
# protected static site. In the same root this script then deploys a preview on a
# fresh hostname while cert-manager's automatic approval is off, writes the status an
# ACME failure leaves onto the preview's CertificateRequest, and lets the deploy stop
# on the certificate. It diagnoses with `domains tls`, renews once, follows issuance
# to Ready, resumes the stopped transaction, and compares the DomainMapping specs and
# the access grants before the failure and after the resume. Evidence goes to $1.
set -euo pipefail

: "${DOCKER_HOST:?the disposable Docker daemon socket}"
: "${NAGARE_DRILL_NAGARECTL:?the packaged candidate nagarectl}"
: "${NAGARE_DRILL_ROOT:?the drill root shared with scripts/site-access-drill.sh}"
: "${NAGARE_DRILL_GHC_ENV:?the GHC package environment that resolves nagare-dsl}"
: "${NAGARE_DRILL_IMAGE_TAG:?the auth image tag the site-access drill seeds}"
OUT="$(cd "${1:?evidence directory}" && pwd)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ROOT="$NAGARE_DRILL_ROOT"
CTX=site-access
NS=personal
SITE=protected-static-site
BASE=127-0-0-1.sslip.io
HOST="$SITE.$NS.$BASE"
PREVIEW=ep191
PREVIEW_HOST="$PREVIEW.$SITE.preview.$BASE"
EXAMPLE="$REPO/cluster/examples/$SITE"
INGRESS_PORT="${NAGARE_DRILL_INGRESS_PORT:-18443}"
log() { printf '%s ep191: %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$OUT/timeline.log"; }

# --- 0. the bootstrapped context and the protected site ---
if [ "${EP191_SKIP_SITE:-0}" != 1 ]; then
  [ "$DOCKER_HOST" != "unix:///Users/shinzui/.colima/nagare-mp23-cp3/docker.sock" ] || { echo "refusing the shared cp3 daemon" >&2; exit 1; }
  "$REPO/scripts/site-access-drill.sh" 2>&1 | tee "$OUT/site-access-drill.log"
  [ "${PIPESTATUS[0]}" = 0 ] || exit 1
fi
for v in $(env | sed -n "s/^\(NAGARE_[A-Z_]*\|CLOUDSDK_[A-Z_]*\|PULUMI_[A-Z_]*\|KUBECONFIG\|SOPS_AGE_KEY_FILE\)=.*/\1/p"); do
  case "$v" in NAGARE_DRILL_*) ;; *) unset "$v" ;; esac
done
export XDG_CONFIG_HOME="$ROOT/config" XDG_STATE_HOME="$ROOT/state" XDG_CACHE_HOME="$ROOT/cache"
export SOPS_AGE_KEY_FILE="$ROOT/sops/age/keys.txt" NAGARE_LOCAL_REGISTRY_FORWARD="127.0.0.1:${NAGARE_DRILL_FORWARD_PORT:-15213}"
set -a; . "$ROOT/images.env"; set +a
export KUBECONFIG="$XDG_CONFIG_HOME/nagare/kubeconfigs/$CTX.yaml"
KUBE="$(kubectl config current-context)"
[ "$KUBE" = "$CTX" ] || { echo "kube context is $KUBE, not $CTX" >&2; exit 1; }
k() { kubectl --context "$KUBE" "$@"; }
N() { "$NAGARE_DRILL_NAGARECTL" --context "$CTX" "$@"; }
log "candidate $(N version --json | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("version"), d.get("revision"))')"
IMAGE_A="$(sed -n 's/.* drill: published .* as \(.*\)$/\1/p' "$OUT/site-access-drill.log" | tail -1)"
[ -n "$IMAGE_A" ] || { echo "the site-access drill log names no image resource" >&2; exit 1; }
mapfile -t STORES < "$ROOT/evidence/stores.txt"
[ "${#STORES[@]}" = 4 ] || { echo "expected four environment stores" >&2; exit 1; }
NAGARE_EN_API_KEY="$(k -n nagare-system get secret nagare-en-api-keys -o jsonpath='{.data.read-write}' | base64 -d)"
export NAGARE_EN_API_KEY
k -n nagare-system port-forward svc/en 18084:80 >/dev/null 2>&1 &
EN_PF=$!
trap 'kill $EN_PF 2>/dev/null || true; [ -n "${PF:-}" ] && kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do nc -z 127.0.0.1 18084 2>/dev/null && break; sleep 1; done
export NAGARE_EN_URL=http://127.0.0.1:18084
snapshot() { # label
  N access list --host "$HOST" > "$OUT/access-$HOST-$1.txt"
  N access list --host "$PREVIEW_HOST" > "$OUT/access-$PREVIEW_HOST-$1.txt" 2>&1 || true
  k -n nagare-system get domainmapping "$HOST" -o json | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["spec"], sort_keys=True))' > "$OUT/spec-$HOST-$1.json"
  k -n nagare-system get domainmapping "$PREVIEW_HOST" -o json | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["spec"], sort_keys=True))' > "$OUT/spec-$PREVIEW_HOST-$1.json"
}
approval() { # off|on
  if [ "$1" = off ]; then
    k -n cert-manager patch deploy cert-manager --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--controllers=*,-certificaterequests-approver"}]' >/dev/null
  else
    idx="$(k -n cert-manager get deploy cert-manager -o json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0]["args"].index("--controllers=*,-certificaterequests-approver"))')"
    k -n cert-manager patch deploy cert-manager --type=json -p "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/args/$idx\"}]" >/dev/null
  fi
  k -n cert-manager rollout status deploy/cert-manager --timeout=180s >/dev/null
  log "cert-manager automatic approval $1"
}

# --- 1. a team grant on the production host, so the access comparison is not empty ---
N access grant --host "$HOST" --team engineering --save-plan "$ROOT/reviews/ep191-grant" > /dev/null
N inventory apply "$ROOT/reviews/ep191-grant" --yes > "$OUT/grant-apply.log" 2>&1
log "granted team engineering on $HOST"

# --- 2. the preview deploy whose certificate fails ---
approval off
N site preview deploy --name "$PREVIEW" -f "$EXAMPLE/nagare/Config.hs" --ghc-env "$NAGARE_DRILL_GHC_ENV" -C "$EXAMPLE" --skip-build --tag "$NAGARE_DRILL_IMAGE_TAG" \
  --image-resource "$IMAGE_A" --preview-env-resource "${STORES[0]}" --preview-env-resource "${STORES[1]}" --preview-env-resource "${STORES[2]}" --preview-env-resource "${STORES[3]}" \
  --save-plan "$ROOT/reviews/ep191-preview" > "$OUT/preview-plan.log" 2>&1
N inventory apply "$ROOT/reviews/ep191-preview" --yes > "$OUT/preview-apply.log" 2>&1 &
APPLY=$!
cr=""
for _ in $(seq 1 300); do
  cr="$(k -n nagare-system get certificaterequests.cert-manager.io -o json | python3 -I -c 'import json,sys; h=sys.argv[1]; print(next((i["metadata"]["name"] for i in json.load(sys.stdin)["items"] if i["metadata"].get("annotations",{}).get("cert-manager.io/certificate-name")==h), ""))' "$PREVIEW_HOST")"
  [ -n "$cr" ] && break; sleep 1
done
[ -n "$cr" ] || { echo "no CertificateRequest for $PREVIEW_HOST" >&2; exit 1; }
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
k -n nagare-system patch certificaterequests.cert-manager.io "$cr" --subresource=status --type=merge -p "{\"status\":{\"failureTime\":\"$now\",\"conditions\":[{\"type\":\"Approved\",\"status\":\"True\",\"reason\":\"cert-manager.io\",\"message\":\"Certificate request has been approved by cert-manager.io\",\"lastTransitionTime\":\"$now\"},{\"type\":\"Ready\",\"status\":\"False\",\"reason\":\"Failed\",\"message\":\"Failed to finalize Order: 404 urn:ietf:params:acme:error:malformed: Certificate not found (EP-191 M4 forced failure)\",\"lastTransitionTime\":\"$now\"}]}}" >/dev/null
for _ in $(seq 1 60); do [ "$(k -n nagare-system get certificates.cert-manager.io "$PREVIEW_HOST" -o jsonpath='{.status.failedIssuanceAttempts}')" = 1 ] && break; sleep 1; done
log "forced failure on $cr"
approval on
snapshot before
if wait "$APPLY"; then echo "the preview apply completed despite the failed certificate" >&2; exit 1; fi
TX="$(sed -n 's/^ambiguous \(tx-[0-9a-f]*\) at .*/\1/p' "$OUT/preview-apply.log" | tail -1)"
[ -n "$TX" ] || { echo "the preview apply did not stop ambiguous: $(tail -3 "$OUT/preview-apply.log")" >&2; exit 1; }
grep -q "^nagarectl: $PREVIEW_HOST: certificate failed after 1 failed attempt" "$OUT/preview-apply.log" && grep -q "run \`nagarectl domains tls $PREVIEW_HOST\`" "$OUT/preview-apply.log" \
  || { echo "the stop does not carry the diagnosis: $(tail -5 "$OUT/preview-apply.log")" >&2; exit 1; }
log "deploy stopped: $TX"

# --- 3. diagnose, refuse what is not ours to renew, renew once, follow to Ready ---
N domains tls "$PREVIEW_HOST" > "$OUT/tls-failed.txt"
N domains tls "$PREVIEW_HOST" --json > "$OUT/tls-failed.json"
grep -q "certificate failed after 1 failed attempt" "$OUT/tls-failed.txt" || { echo "domains tls did not say failed" >&2; exit 1; }
if N domains tls "$HOST" --renew --yes > "$OUT/renew-ready-refused.txt" 2>&1; then echo "renew of a Ready host was allowed" >&2; exit 1; fi
grep -q "the certificate is Ready" "$OUT/renew-ready-refused.txt" || { echo "the Ready refusal is missing" >&2; exit 1; }
N domains tls "$PREVIEW_HOST" --renew --yes > "$OUT/renew.txt" 2>&1
log "renewed $PREVIEW_HOST"
verdict=""
for _ in $(seq 1 120); do
  verdict="$(N domains tls "$PREVIEW_HOST" --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["verdict"])')"
  [ "$verdict" = ready ] && break; sleep 1
done
[ "$verdict" = ready ] || { echo "the certificate did not turn ready: $verdict" >&2; exit 1; }
N domains tls "$PREVIEW_HOST" > "$OUT/tls-ready.txt"
if N domains tls "$PREVIEW_HOST" --renew --yes > "$OUT/renew-again-refused.txt" 2>&1; then echo "a second renew was allowed" >&2; exit 1; fi
log "certificate ready"

# --- 4. resume the stopped deploy, then compare ---
for n in $(seq 1 6); do
  if N inventory resume "$TX" --yes > "$OUT/resume-$n.log" 2>&1; then break; fi
  grep -q "^ambiguous $TX at " "$OUT/resume-$n.log" || { echo "resume failed: $(tail -3 "$OUT/resume-$n.log")" >&2; exit 1; }
  [ "$n" != 6 ] || { echo "resume did not converge" >&2; exit 1; }
  sleep 20
done
log "resumed $TX"
N inventory status --json > "$OUT/inventory-status.json"
snapshot after
for f in "access-$HOST" "access-$PREVIEW_HOST" "spec-$HOST" "spec-$PREVIEW_HOST"; do
  ext=txt; case "$f" in spec-*) ext=json ;; esac
  cmp -s "$OUT/$f-before.$ext" "$OUT/$f-after.$ext" || { echo "$f changed across the recovery" >&2; diff "$OUT/$f-before.$ext" "$OUT/$f-after.$ext" >&2; exit 1; }
done
grep -q engineering "$OUT/access-$HOST-after.txt" || { echo "the team grant is missing from the access list" >&2; exit 1; }
log "access lists and DomainMapping specs unchanged"

# --- 5. the preview answers over the local CA ---
k -n cert-manager get secret nagare-local-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "$ROOT/ca.pem"
k -n kourier-system port-forward svc/kourier "$INGRESS_PORT:443" >/dev/null 2>&1 &
PF=$!
for _ in $(seq 1 30); do nc -z 127.0.0.1 "$INGRESS_PORT" 2>/dev/null && break; sleep 1; done
code=""
for _ in $(seq 1 120); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$ROOT/ca.pem" --connect-to "$PREVIEW_HOST:443:127.0.0.1:$INGRESS_PORT" "https://$PREVIEW_HOST/" 2>/dev/null || true)"
  [ "$code" = 302 ] && break; sleep 1
done
[ "$code" = 302 ] || { echo "the preview did not answer 302 over the local CA: $code" >&2; exit 1; }
log "anonymous preview answers 302 over the local CA"
unset NAGARE_EN_API_KEY
log "M4 drill OK"
