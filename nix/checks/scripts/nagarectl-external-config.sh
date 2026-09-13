#!/usr/bin/env bash
set -euo pipefail

mkdir -p isolated/nagare
cp "$src/cluster/examples/hello-knative-service/nagare/Config.hs" isolated/nagare/Config.hs
cd isolated
unset GHC_ENVIRONMENT NAGARE_GHC_ENVIRONMENT
nagarectl deploy --dry-run --file "$PWD/nagare/Config.hs" > output
grep -q "kind: Service" output
grep -q "name: hello" output

cat > nagare/Invalid.hs <<'INVALID_CONFIG'
module Main where

import Nagare.Dsl.Config (emitDeployment)

main :: IO ()
main = emitDeployment missingDeployment
INVALID_CONFIG
if nagarectl deploy --dry-run --file "$PWD/nagare/Invalid.hs" \
  > invalid-output 2> invalid-error; then
  echo "invalid typed config unexpectedly succeeded" >&2
  exit 1
fi
grep -q "nagare: compile error" invalid-error
if grep -Eqi 'docker|kubectl|knative' invalid-output invalid-error; then
  echo "invalid typed config reached an external deployment phase" >&2
  exit 1
fi
touch "$out"
