#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
issuer_patch="$repo_root/cluster/bootstrap/knative-serving/config-certmanager.yaml"
tls_patch="$repo_root/cluster/bootstrap/knative-serving/config-network-tls.yaml"

assert_issuer() {
  local key="$1"
  local name="$2"
  yq -e "((.data.${key} | from_yaml).kind == \"ClusterIssuer\") and ((.data.${key} | from_yaml).name == \"${name}\")" \
    "$issuer_patch" >/dev/null
}

assert_issuer issuerRef letsencrypt-dns
assert_issuer clusterLocalIssuerRef knative-selfsigned-issuer
assert_issuer systemInternalIssuerRef knative-selfsigned-issuer

yq -e '.data."external-domain-tls" == "Enabled"' "$tls_patch" >/dev/null
yq -e \
  '.data."namespace-wildcard-cert-selector" | from_yaml | .matchLabels."nagare.dev/app-namespace" == "true"' \
  "$tls_patch" >/dev/null

cloud_dry_run="$(mktemp)"
local_dry_run="$(mktemp)"
trap 'rm -f -- "$cloud_dry_run" "$local_dry_run"' EXIT
just --justfile "$repo_root/justfile" --dry-run cluster-bootstrap >"$cloud_dry_run" 2>&1
just --justfile "$repo_root/justfile" --dry-run local-bootstrap >"$local_dry_run" 2>&1

for transcript in "$cloud_dry_run" "$local_dry_run"; do
  grep -Fxq 'kubectl label namespace personal nagare.dev/app-namespace=true --overwrite' "$transcript"
  if grep -Eq 'kubectl label namespace (cert-manager|knative-serving|kourier-system|nagare-system|monitoring)' "$transcript"; then
    echo "FAIL: bootstrap opts a system namespace into public wildcard certificates" >&2
    exit 1
  fi
done

line_of() {
  local transcript="$1"
  local needle="$2"
  awk -v needle="$needle" 'index($0, needle) { print NR; exit }' "$transcript"
}

assert_order() {
  local transcript="$1"
  shift
  local previous=0
  local needle line
  for needle in "$@"; do
    line="$(line_of "$transcript" "$needle")"
    if [ -z "$line" ] || [ "$line" -le "$previous" ]; then
      echo "FAIL: expected '$needle' after line $previous in $transcript" >&2
      exit 1
    fi
    previous="$line"
  done
}

assert_order "$cloud_dry_run" \
  'retry-knative-configmap-patch.sh config-certmanager' \
  'nagarectl cluster certificate-policy' \
  'nagarectl platform stamp'

tls_dry_run="$(just --justfile "$repo_root/justfile" --dry-run cluster-enable-tls 2>&1)"
case "$tls_dry_run" in
  *'config-network-tls.yaml'*'nagarectl cluster certificate-policy'*'nagarectl platform stamp'*) ;;
  *)
    echo "FAIL: TLS enable must validate certificate policy before stamping" >&2
    exit 1
    ;;
esac

echo "ok: issuer roles and namespace wildcard opt-in policy are explicit"
