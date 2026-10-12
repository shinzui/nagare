#!/usr/bin/env bash
set -euo pipefail
capture="${NAGARE_HELM_CAPTURE_PATH:-}"
if [[ "${capture}" != /* ]]; then
  echo "nagare: Helm review capture path must be absolute" >&2
  exit 2
fi
umask 077
set -C
cat > "${capture}"
cat "${capture}"
