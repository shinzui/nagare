#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "external typed config check failed at line $LINENO: $BASH_COMMAND" >&2; if test -f output; then cat output >&2; fi; if test -f valid-error; then cat valid-error >&2; fi; if test -f invalid-error; then cat invalid-error >&2; fi; if test -f constructor-error; then cat constructor-error >&2; fi' ERR

mkdir -p isolated/nagare isolated/home isolated/config isolated/state
cp "$src/cluster/examples/hello-knative-service/nagare/Config.hs" isolated/nagare/Config.hs
cd isolated
export HOME="$PWD/home"
export XDG_CONFIG_HOME="$PWD/config"
export XDG_STATE_HOME="$PWD/state"
unset GHC_ENVIRONMENT NAGARE_GHC_ENVIRONMENT
runghc -XGHC2024 -i"$PWD/nagare" "$PWD/nagare/Config.hs" > output
jq -e '.name == "hello" and .namespace == "personal"' output >/dev/null
if nagarectl deploy --dry-run --file "$PWD/nagare/Config.hs" \
  --tag fixture --image-resource publication:hello/image/main > valid-output 2> valid-error; then
  echo "unaccepted image unexpectedly produced a reviewed deployment" >&2
  exit 1
fi
grep -q 'platform foundation scope is absent from accepted inventory history' valid-error

cat > nagare/Invalid.hs <<'INVALID_CONFIG'
module Main where

import Nagare.Dsl.Config (emitDeployment)

main :: IO ()
main = emitDeployment missingDeployment
INVALID_CONFIG
if nagarectl deploy --dry-run --file "$PWD/nagare/Invalid.hs" \
  --tag fixture --image-resource publication:hello/image/main \
  > invalid-output 2> invalid-error; then
  echo "invalid typed config unexpectedly succeeded" >&2
  exit 1
fi
grep -q "nagare: compile error" invalid-error
if grep -Eqi 'docker|kubectl|knative' invalid-output invalid-error; then
  echo "invalid typed config reached an external deployment phase" >&2
  exit 1
fi

cat > nagare/PrivateConstructor.hs <<'PRIVATE_CONSTRUCTOR'
module Main where

import Nagare.Dsl.Types (ServiceName (..))
import Data.Text qualified as Text

main :: IO ()
main = print (ServiceName (Text.pack "forged"))
PRIVATE_CONSTRUCTOR
if runghc -XGHC2024 -i"$PWD/nagare" "$PWD/nagare/PrivateConstructor.hs" \
  > constructor-output 2> constructor-error; then
  echo "private typed-config constructor is public" >&2
  exit 1
fi
grep -q 'ServiceName' constructor-error
grep -q 'Illegal term-level use of the type constructor' constructor-error
touch "$out"
