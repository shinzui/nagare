#!/usr/bin/env bash
set -uo pipefail
ref="git+file:///work/nagare?rev=3ae20f8c9ed5bcfaa1681a7c3a3a927d6ede773b"
r=$(mktemp -d); mkdir -p $r/home $r/config $r/state $r/work; cd $r/work
export HOME=$r/home XDG_CONFIG_HOME=$r/config XDG_STATE_HOME=$r/state
nix run "$ref#nagarectl" -- context create local --mode local --registry-host localhost:5000 --base-domain 127-0-0-1.sslip.io --local-object-store http://minio:9000/nagare-backups --use 2>&1 | grep -v "could not read HEAD\|untrusted flake\|accept-flake-config"
nix run "$ref#nagare" -- --dry-run local-up > local-init.out 2>&1
echo "local-up exit=$?"
grep -v "could not read HEAD\|untrusted flake\|accept-flake-config" local-init.out | tail -40
