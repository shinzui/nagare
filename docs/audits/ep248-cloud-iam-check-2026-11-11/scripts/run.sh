#!/usr/bin/env bash
# Run one ep248 step from an empty environment: run.sh STEP [ARGS...]
set -euo pipefail
SP="$HOME/.local/state/nagare/drills/ep248-cloud"
PKG="${PKG_OVERRIDE:-$(readlink "$SP/pkg")}"
mkdir -p /private/tmp/ep248-tmp
step="$1"; shift
exec caffeinate -i env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" TERM=dumb TMPDIR=/private/tmp/ep248-tmp \
  REV="${REV:-}" PKG_OVERRIDE="${PKG_OVERRIDE:-}" NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" \
  PATH="$PKG/bin:$PATH" \
  bash "$SP/ep248-$step.sh" "$@"
