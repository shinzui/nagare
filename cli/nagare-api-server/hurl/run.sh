#!/usr/bin/env bash
# Run the admin API's black-box suite against an already running server.
set -euo pipefail
cd "$(dirname "$0")"
hurl --test --variables-file vars.env \
  health.hurl \
  platform.hurl \
  inventory.hurl \
  sites.hurl \
  access.hurl \
  errors.hurl
