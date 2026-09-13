#!/usr/bin/env bash
set -euo pipefail

root="$payload/share/nagare"
jq -e '.assetSchemaVersion == 1 and (.payloadId | length > 0)' "$root/release.json" >/dev/null
test -f "$root/infra/pulumi/Pulumi.yaml"
test -f "$root/cli/nagare-dsl/nagare-dsl.cabal"
test -f "$root/cli/nagare-access/nagare-access.cabal"
test -f "$root/cli/nagare-access/Dockerfile"
test -f "$root/cluster/bootstrap/render-context-template.sh"
test -f "$root/cluster/examples/uploads-volume/nagare/Config.hs"
test ! -e "$root/cluster/secrets"
test -f "$root/nixos/flake.nix"
test -f "$root/scripts/lib/target.sh"
test -f "$root/scripts/lib/release.sh"
test -f "$root/scripts/lib/cluster-secrets.sh"
test -f "$root/justfile"
test -f "$root/docs/user/reference.md"
touch "$out"
