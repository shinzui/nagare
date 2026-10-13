#!/usr/bin/env bash
# EP-191 M1: prove the renew patch on cert-manager v1.20.2 in a disposable local k3d
# cluster. With automatic approval off, force one failed issuance by writing onto the
# CertificateRequest the status an ACME failure leaves (EP191_FAILURE=failed: Approved,
# Ready=False reason Failed, failureTime) or a denial (EP191_FAILURE=denied), then
# trigger re-issuance with the JSON status patch that `nagarectl domains tls HOST
# --renew --yes` applies. Prints every kubectl call.
set -euo pipefail
: "${KUBECONFIG:?the kubeconfig of the disposable cluster}"
OUT="${1:?output directory}"
HOST="${EP191_HOST:-protected-static-site.personal.127-0-0-1.sslip.io}"
HOST_NS="${EP191_HOST_NS:-nagare-system}"
FAILURE="${EP191_FAILURE:-failed}"
NS=ep191-probe
CERT=ep191-probe
ts() { date -u +%H:%M:%S; }
k() { printf '%s + kubectl %s\n' "$(ts)" "$*" >&2; kubectl "$@"; }
summary() { k get certificates.cert-manager.io "$CERT" -n "$NS" -o json | jq '{resourceVersion: .metadata.resourceVersion, generation: .metadata.generation, status: .status}'; }
requests() { k get certificaterequests.cert-manager.io -n "$NS" -o json | jq -c '.items[] | {name: .metadata.name, uid: .metadata.uid, revision: .metadata.annotations["cert-manager.io/certificate-revision"], created: .metadata.creationTimestamp, conditions: [.status.conditions[]? | {type, status, reason}]}'; }

server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
case "$server" in https://0.0.0.0:*|https://127.0.0.1:*) ;; *) echo "not a loopback cluster: $server" >&2; exit 1 ;; esac
node="$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')"
[ "$node" = k3d-nagare-local-server-0 ] || { echo "unexpected node: $node" >&2; exit 1; }
echo "$(ts) cluster $server node $node cert-manager $(kubectl -n cert-manager get deploy cert-manager -o jsonpath='{.spec.template.spec.containers[0].image}')"

echo "== ownership chain of $HOST"
{
  k get domainmappings.serving.knative.dev "$HOST" -n "$HOST_NS" -o json | jq '{kind, name: .metadata.name, uid: .metadata.uid, annotations: (.metadata.annotations | with_entries(select(.key | startswith("nagare.dev/")))), ownerReferences: .metadata.ownerReferences}'
  k get certificates.networking.internal.knative.dev "$HOST" -n "$HOST_NS" -o json | jq '{kind, name: .metadata.name, uid: .metadata.uid, secretName: .spec.secretName, ownerReferences: .metadata.ownerReferences}'
  k get certificates.cert-manager.io "$HOST" -n "$HOST_NS" -o json | jq '{kind, name: .metadata.name, uid: .metadata.uid, secretName: .spec.secretName, issuerRef: .spec.issuerRef, ownerReferences: .metadata.ownerReferences, status: .status}'
  k get certificaterequests.cert-manager.io -n "$HOST_NS" -o json | jq --arg h "$HOST" '.items[] | select(.metadata.ownerReferences[]?.name == $h) | {kind, name: .metadata.name, revision: .metadata.annotations["cert-manager.io/certificate-revision"], ownerReferences: .metadata.ownerReferences}'
} | jq -s . > "$OUT/ownership.json"
jq -c '.[] | {kind, name, uid, owners: [.ownerReferences[]? | {kind, name, uid, controller}]}' "$OUT/ownership.json"

echo "== 1. automatic approval off"
k -n cert-manager patch deploy cert-manager --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--controllers=*,-certificaterequests-approver"}]'
k -n cert-manager rollout status deploy/cert-manager --timeout=180s

echo "== 2. a Certificate on nagare-local-ca, its request $FAILURE"
k create namespace "$NS" --dry-run=client -o yaml | k apply -f -
k apply -f - <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: $CERT, namespace: $NS}
spec:
  secretName: $CERT-tls
  dnsNames: [$CERT.127-0-0-1.sslip.io]
  issuerRef: {kind: ClusterIssuer, name: nagare-local-ca}
YAML
for _ in $(seq 1 60); do cr="$(kubectl get certificaterequests.cert-manager.io -n "$NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"; [ -n "$cr" ] && break; sleep 1; done
[ -n "$cr" ] || { echo "no CertificateRequest appeared" >&2; exit 1; }
firstUid="$(kubectl get certificaterequests.cert-manager.io "$cr" -n "$NS" -o jsonpath='{.metadata.uid}')"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
case "$FAILURE" in
  denied) statusPatch="$(jq -cn --arg now "$now" '{status: {conditions: [{type: "Denied", status: "True", reason: "EP191ForcedFailure", message: "EP-191 M1 forced failure", lastTransitionTime: $now}]}}')" ;;
  failed) statusPatch="$(jq -cn --arg now "$now" '{status: {failureTime: $now, conditions: [{type: "Approved", status: "True", reason: "cert-manager.io", message: "Certificate request has been approved by cert-manager.io", lastTransitionTime: $now}, {type: "Ready", status: "False", reason: "Failed", message: "Failed to finalize Order: 404 urn:ietf:params:acme:error:malformed: Certificate not found (EP-191 M1 forced failure)", lastTransitionTime: $now}]}}')" ;;
  *) echo "EP191_FAILURE is failed or denied" >&2; exit 1 ;;
esac
k patch certificaterequests.cert-manager.io "$cr" -n "$NS" --subresource=status --type=merge -p "$statusPatch"
for _ in $(seq 1 60); do [ "$(kubectl get certificates.cert-manager.io "$CERT" -n "$NS" -o jsonpath='{.status.failedIssuanceAttempts}')" = 1 ] && break; sleep 1; done
echo "-- Certificate after the forced failure"; summary | tee "$OUT/certificate-failed.json"
requests | tee "$OUT/requests-failed.jsonl"

echo "== 3. automatic approval restored"
idx="$(kubectl -n cert-manager get deploy cert-manager -o json | jq '.spec.template.spec.containers[0].args | index("--controllers=*,-certificaterequests-approver")')"
k -n cert-manager patch deploy cert-manager --type=json -p "[{\"op\":\"test\",\"path\":\"/spec/template/spec/containers/0/args/$idx\",\"value\":\"--controllers=*,-certificaterequests-approver\"},{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/args/$idx\"}]"
k -n cert-manager rollout status deploy/cert-manager --timeout=180s
sleep 30
echo "-- 30 s after restoring approval, backoff holds:"; requests

echo "== 4. a stale resourceVersion fails the test"
cur="$(kubectl get certificates.cert-manager.io "$CERT" -n "$NS" -o json)"
rv="$(jq -r .metadata.resourceVersion <<<"$cur")"; gen="$(jq -r .metadata.generation <<<"$cur")"
i="$(jq '[.status.conditions[].type] | index("Issuing")' <<<"$cur")"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
patch() { printf '[{"op":"test","path":"/metadata/resourceVersion","value":"%s"},{"op":"replace","path":"/status/conditions/%s","value":{"type":"Issuing","status":"True","reason":"ManuallyTriggered","message":"Certificate re-issuance manually triggered","observedGeneration":%s,"lastTransitionTime":"%s"}}]' "$1" "$i" "$gen" "$now"; }
if k patch certificates.cert-manager.io "$CERT" -n "$NS" --subresource=status --type=json -p "$(patch 1)" 2>"$OUT/stale.err"; then echo "stale patch applied" >&2; exit 1; fi
cat "$OUT/stale.err"

echo "== 5. the renew patch (resourceVersion $rv, Issuing at index $i, generation $gen)"
patch "$rv" | jq . > "$OUT/renew-patch.json"
started="$(date +%s)"
k patch certificates.cert-manager.io "$CERT" -n "$NS" --subresource=status --type=json -p "$(patch "$rv")"
for _ in $(seq 1 120); do [ "$(kubectl get certificates.cert-manager.io "$CERT" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ] && break; sleep 1; done
echo "-- Ready after $(( $(date +%s) - started )) s"
summary | tee "$OUT/certificate-renewed.json"
requests | tee "$OUT/requests-renewed.jsonl"
uids="$(kubectl get certificaterequests.cert-manager.io -n "$NS" -o jsonpath='{.items[*].metadata.uid}')"
case " $uids " in *" $firstUid "*) echo "the failed request $cr ($firstUid) still exists" >&2; exit 1 ;; esac
[ "$(kubectl get certificates.cert-manager.io "$CERT" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ] || { echo "the Certificate is not Ready" >&2; exit 1; }
echo "-- the failed request $cr ($firstUid) is gone; the new request is $uids"

echo "== 6. cleanup"
k delete namespace "$NS" --wait=false
echo "$(ts) M1 OK"
