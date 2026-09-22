#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT="$(mktemp)"
trap 'rm -f "${OUT}"' EXIT

cd "${PKG_DIR}"
cabal build --verbose=0 lib:nagarectl
cabal exec --verbose=0 -- ghc -fno-code -package nagarectl test/negative/GoodInventoryExecutionAPI.hs

if cabal exec --verbose=0 -- ghc -fno-code -package nagarectl test/negative/BadExecutableEscape.hs >"${OUT}" 2>&1; then
  echo "FAIL: lock-scoped ExecutablePlan escaped"
  exit 1
fi

if ! tr '\n' ' ' <"${OUT}" | grep -qE "Couldn't match type.*s|type variable.*escape|rigid.*type variable"; then
  echo "FAIL: negative fixture failed for an unexpected reason"
  cat "${OUT}"
  exit 1
fi

echo "PASS: ExecutablePlan cannot escape the process-lock scope"
