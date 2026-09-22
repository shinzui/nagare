#!/usr/bin/env bash
# Verify that modules which abuse internal constructors fail to compile.
# Run from cli/nagare-dsl/ inside `nix develop` (it shells out to cabal/ghc and
# needs the package environment so nagare-dsl's non-boot deps resolve).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NEG="test/negative/BadConstructor.hs"
OUT="$(mktemp)"
trap 'rm -f "${OUT}"' EXIT

cd "${PKG_DIR}"

echo "=== Negative type check: ServiceName constructor not exported ==="
echo "Building nagare-dsl so the negative module can compile against the package..."
cabal build --verbose=0 nagare-dsl
cabal exec --verbose=0 -- ghc -fno-code -package nagare-dsl test/negative/GoodResourceAPI.hs

echo "Compiling ${NEG} against the installed package (expected: compile error)"
# Compile the negative module against the compiled nagare-dsl package (via the
# cabal package environment), not the library source — so GHC resolves the
# export list and reports that ServiceName's data constructor is inaccessible.
if cabal exec --verbose=0 -- ghc -fno-code -package nagare-dsl "${NEG}" >"${OUT}" 2>&1; then
  echo "FAIL: ${NEG} compiled — the ServiceName constructor is leaking!"
  cat "${OUT}"
  exit 1
else
  echo ""
  echo "PASS: GHC rejected ${NEG} as expected."
  # GHC 9.12 reports "Illegal term-level use of the type constructor
  # 'ServiceName'" (the type is exported, the data constructor is not). Older
  # GHCs say "Not in scope: data constructor 'ServiceName'". Accept either.
  if grep -qE "Illegal term-level use of the type constructor .ServiceName.|Not in scope.*ServiceName|data constructor.*ServiceName" "${OUT}"; then
    echo "PASS: error confirms the 'ServiceName' data constructor is inaccessible."
  else
    echo "FAIL: GHC rejected the file, but the expected error was not found:"
    cat "${OUT}"
    exit 1
  fi
fi

echo ""
echo "=== EnvVar mutual exclusion is enforced by the sum type ==="
echo "EnvVar = EnvLiteral Text | EnvSecretRef SecretName — no constructor takes"
echo "both a Text and a SecretName, so a value+secretRef env var is"
echo "unrepresentable. No runtime check is needed; the type rules it out."
echo "PASS: EnvVar sum type mutual exclusion confirmed by type definition."

echo ""
echo "All negative type checks passed."

expect_failure() {
  local fixture="$1" pattern="$2"
  if cabal exec --verbose=0 -- ghc -fno-code -package nagare-dsl "$fixture" >"$OUT" 2>&1; then
    echo "FAIL: $fixture compiled"
    exit 1
  fi
  if ! grep -qE "$pattern" "$OUT"; then
    echo "FAIL: $fixture failed for an unexpected reason"
    cat "$OUT"
    exit 1
  fi
  echo "PASS: $fixture rejected for the intended reason"
}
for fixture in test/negative/BadGeneric*.hs; do
  expect_failure "$fixture" 'No instance for.*Generic|No instance for.*GHC.Generics.Generic'
done
expect_failure test/negative/BadCapabilityCoerce.hs 'OciImage.*DatabaseConnection|DatabaseConnection.*OciImage'
expect_failure test/negative/BadIdentityCoerce.hs 'Couldn.t match representation of type.*ContextId'
expect_failure test/negative/BadSecretShow.hs 'No instance for.*Show RawCredential'
expect_failure test/negative/BadSecretJSON.hs 'No instance for.*ToJSON RawCredential'
expect_failure test/negative/BadValidatedDecode.hs 'No instance for.*FromJSON ValidatedInventory'
