#!/usr/bin/env bash
set -euo pipefail

cache_dir="cluster/bootstrap/nix-cache"
expected_attic_digest="sha256:317924e10e70416e69d401880bb71b3aae69b413ecafcfc54018f61929464526"
expected_smoke_digest="sha256:85169a7ff4ac6928b70b15ced20c74770e07e8fbc7f97e92f64c1fca47ea9486"

for file in \
  README.md \
  create-secret.sh \
  publish-image.sh \
  install.sh \
  status.sh \
  server.toml.tmpl \
  config-check-job.yaml.tmpl \
  migration-job.yaml.tmpl \
  workloads.yaml.tmpl \
  networkpolicies.yaml \
  client-configmap.yaml.tmpl \
  smoke/flake.nix \
  smoke/flake.lock \
  smoke-pod.yaml
do
  test -s "${cache_dir}/${file}"
done

# OpenSSL 3 needs `-traditional` for PKCS#1, while macOS LibreSSL rejects that
# flag and already writes PKCS#1. Keep both branches in the operator script.
grep -Fq 'openssl genrsa -traditional' "${cache_dir}/create-secret.sh"
grep -Fq 'openssl genrsa -out' "${cache_dir}/create-secret.sh"
grep -Fq 'cd "${secrets_dir}"' "${cache_dir}/create-secret.sh"
grep -Fq 'skopeo --policy "${policy}" inspect' "${cache_dir}/publish-image.sh"
grep -Fq 'skopeo --policy "${policy}" copy --preserve-digests' "${cache_dir}/publish-image.sh"
grep -Fq 'run-reviewed-bootstrap.sh' "${cache_dir}/install.sh"

# Parse all committed YAML and rendered templates as one multi-document stream.
{
  for template in config-check-job migration-job workloads; do
    sed "s|\${ATTIC_IMAGE}|example.invalid/attic@${expected_attic_digest}|g" \
      "${cache_dir}/${template}.yaml.tmpl"
    printf '\n---\n'
  done
  cat "${cache_dir}/networkpolicies.yaml"
  printf '\n---\n'
  sed 's|${ATTIC_PUBLIC_KEY}|nagare-cache-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=|g' \
    "${cache_dir}/client-configmap.yaml.tmpl"
  printf '\n---\n'
  cat "${cache_dir}/secret.example.yaml"
  printf '\n---\n'
  cat "${cache_dir}/smoke-pod.yaml"
} | yq eval-all '.' - >/dev/null

grep -Fq "image: nixos/nix@${expected_smoke_digest}" "${cache_dir}/smoke-pod.yaml"
test "$(grep -Fc "image: nixos/nix@${expected_smoke_digest}" "${cache_dir}/smoke-pod.yaml")" -eq 2
! grep -REn 'image: .+:(latest|main)([[:space:]]|$)' "${cache_dir}"

grep -Fq 'readOnlyRootFilesystem: true' "${cache_dir}/workloads.yaml.tmpl"
grep -Fq 'automountServiceAccountToken: false' "${cache_dir}/workloads.yaml.tmpl"
grep -Fq 'runAsUser: 65532' "${cache_dir}/workloads.yaml.tmpl"
grep -Fq 'capabilities: {drop: ["ALL"]}' "${cache_dir}/workloads.yaml.tmpl"
grep -Fq 'concurrencyPolicy: Forbid' "${cache_dir}/workloads.yaml.tmpl"
grep -Fq 'nagare.dev/nix-cache-client: "true"' "${cache_dir}/networkpolicies.yaml"
grep -Fq 'substituters = http://nix-cache-internal.nagare-system.svc.cluster.local:8080/nagare-cache' \
  "${cache_dir}/client-configmap.yaml.tmpl"

grep -Fq '> 80' cluster/observability/vmrules/nagare-alerts.yaml
grep -Fq '> 90' cluster/observability/vmrules/nagare-alerts.yaml
grep -A8 -F 'alert: DiskUsageCritical' cluster/observability/vmrules/nagare-alerts.yaml | \
  grep -Fq 'for: 15m'
