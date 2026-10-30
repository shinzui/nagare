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
# EP-222: package a protected static site from an unrelated directory with no
# provider reachable. Each provider tool is a shim that records its call and
# fails, so any use is caught; the context must match the generators and the tree.
mkdir -p ../package/nagare ../package/shims
cp "$src/cluster/examples/protected-static-site/nagare/Config.hs" ../package/nagare/Config.hs
cp -R "$src/cluster/examples/protected-static-site/public" ../package/public
cd ../package
for tool in docker kubectl gcloud skopeo; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/provider-calls"\nexit 97\n' "$tool" "$PWD" > "shims/$tool"
  chmod +x "shims/$tool"
done
PATH="$PWD/shims:$PATH" nagarectl site package --file "$PWD/nagare/Config.hs" --context-out "$PWD/context" > package-output
grep -q '^content-digest: sha256:' package-output
test -f context/Dockerfile
grep -q 'COPY site/ /usr/share/nginx/html/' context/Dockerfile
grep -q 'listen 8080' context/nginx.conf
diff -r public context/site
if test -e provider-calls; then
  echo "site package reached a provider:" >&2
  cat provider-calls >&2
  exit 1
fi
if PATH="$PWD/shims:$PATH" nagarectl site package --file "$PWD/nagare/Config.hs" --context-out "$PWD/context" 2> existing-error; then
  echo "site package replaced an existing context" >&2
  exit 1
fi
grep -q 'already exists' existing-error
touch "$out"
