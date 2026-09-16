#!/usr/bin/env bash
set -euo pipefail

root="$payload/share/nagare"
jq -e '.assetSchemaVersion == 1 and (.payloadId | length > 0)' "$root/release.json" >/dev/null
test -f "$root/infra/pulumi/Pulumi.yaml"
test -f "$root/cli/nagare-dsl/nagare-dsl.cabal"
test -f "$root/cli/nagare-access/nagare-access.cabal"
test -f "$root/cli/nagare-access/Dockerfile"
test -f "$root/cluster/bootstrap/render-context-template.sh"
test -s "$root/cluster/bootstrap/net-certmanager/nagare-net-certmanager-controller.tar.gz"
test -s "$root/cluster/bootstrap/nix-cache/attic-server-image.tar.gz"
test -s "$root/cluster/bootstrap/nix-cache/attic-pin.json"
for file in \
  create-secret.sh publish-image.sh install.sh status.sh server.toml.tmpl \
  config-check-job.yaml.tmpl migration-job.yaml.tmpl workloads.yaml.tmpl \
  networkpolicies.yaml client-configmap.yaml.tmpl smoke/flake.nix smoke/flake.lock smoke-pod.yaml
do
  test -s "$root/cluster/bootstrap/nix-cache/$file"
done
jq -e '
  .sourceCommit == "12cbeca141f46e1ade76728bce8adc447f2166c6" and
  .linuxAmd64Digest == "sha256:317924e10e70416e69d401880bb71b3aae69b413ecafcfc54018f61929464526"
' "$root/cluster/bootstrap/nix-cache/attic-pin.json" >/dev/null
grep -qx 'nagare/net-certmanager-controller:v1.14.0-nagare.1' \
  "$root/cluster/bootstrap/net-certmanager/image-reference"
test -f "$root/cluster/examples/uploads-volume/nagare/Config.hs"
test ! -e "$root/cluster/secrets"
test -f "$root/nixos/flake.nix"
test -f "$root/scripts/lib/target.sh"
test -f "$root/scripts/lib/release.sh"
test -f "$root/scripts/lib/cluster-secrets.sh"
grep -q 'send-file <instance> <local-path> -- <command' "$root/scripts/iap-ssh.sh"
grep -q 'send-file) cmd_send_file' "$root/scripts/iap-ssh.sh"
test -f "$root/justfile"
test -f "$root/docs/user/reference.md"
touch "$out"
