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
  grep -Fxq 'scripts/run-reviewed-bootstrap.sh' "$transcript"
  if grep -Eq 'kubectl (apply|patch|label)|nagarectl platform stamp' "$transcript"; then
    echo "FAIL: bootstrap bypasses reviewed inventory" >&2
    exit 1
  fi
done
grep -Fq '"nagare.dev/app-namespace" .= ("true" :: Text) | name == "personal"' \
  "$repo_root/cli/nagarectl/src/Nagare/Inventory/Components/Foundation.hs"

tls_dry_run="$(just --justfile "$repo_root/justfile" --dry-run cluster-enable-tls 2>&1)"
case "$tls_dry_run" in
  *'NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED=1'*'scripts/run-reviewed-bootstrap.sh'*) ;;
  *)
    echo "FAIL: TLS enable must use the persisted context policy and reviewed bootstrap" >&2
    exit 1
    ;;
esac

echo "ok: issuer roles and namespace wildcard opt-in policy are explicit"
