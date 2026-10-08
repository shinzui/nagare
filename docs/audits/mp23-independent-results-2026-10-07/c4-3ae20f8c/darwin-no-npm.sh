#!/usr/bin/env bash
set -uo pipefail
ref="git+file:///private/tmp/nagare-cand-3ae20f8c-src?rev=3ae20f8c9ed5bcfaa1681a7c3a3a927d6ede773b"
r=$(mktemp -d "${TMPDIR:-/tmp}/c4-no-npm.XXXXXX"); mkdir -p $r/home $r/config $r/state $r/work $r/bin; cd $r/work
for t in bash git mkdir nix; do ln -s "$(command -v $t)" $r/bin/$t; done
for name in ${!NAGARE_@} ${!CLOUDSDK_@} ${!PULUMI_@}; do unset "$name"; done
export HOME=$r/home XDG_CONFIG_HOME=$r/config XDG_STATE_HOME=$r/state
nix run "$ref#nagarectl" -- context create local --mode local --registry-host localhost:5000 --base-domain 127-0-0-1.sslip.io --local-object-store http://minio:9000/nagare-backups --use 2>&1 | grep -v "untrusted flake\|accept-flake-config"
echo "-- with host PATH (npm present: $(command -v npm))"
nix run "$ref#nagare" -- --dry-run local-up > with-npm.out 2>&1; echo "local-up exit=$?"
rm -rf $r/state/nagare/local/platform
echo "-- with PATH=bash,git,mkdir,nix only"
PATH=$r/bin nix run "$ref#nagare" -- --dry-run local-up > no-npm.out 2>&1; echo "local-up exit=$?"
grep -v "untrusted flake\|accept-flake-config" no-npm.out | tail -6
rm -rf "$r"
