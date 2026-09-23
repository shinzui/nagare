#!/usr/bin/env bash
set -euo pipefail

expected="${NAGARE_HELM_REVIEW_SHA256:-}"
if [[ ! "${expected}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "nagare: reviewed Helm manifest digest is missing or malformed" >&2
  exit 2
fi

manifest="$(mktemp "${TMPDIR:-/tmp}/nagare-helm-review.XXXXXX")"
chmod 600 "${manifest}"
trap 'rm -f "${manifest}"' EXIT
cat > "${manifest}"

actual="$(openssl dgst -sha256 -r "${manifest}")"
actual="${actual%% *}"
if [[ "${actual}" != "${expected}" ]]; then
  echo "nagare: Helm rendered manifests differ from the retained review" >&2
  exit 1
fi

cat "${manifest}"
