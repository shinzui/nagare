#!/usr/bin/env bash
# EP-253: the packaged CLI and SDK used by a consumer that has nothing else:
# no Nagare checkout, no Cabal environment, no user package database, an empty
# HOME and no network. It expects $cli, $sdk, $fixture and $out from the
# derivation, and writes the run's evidence to $out/evidence.json.
set -Eeuo pipefail
trap 'echo "SDK consumer check failed at line $LINENO: $BASH_COMMAND" >&2; for f in check.out check.err ghc.out ghc.err invalid.out invalid.err; do test -f "$f" && { echo "--- $f"; cat "$f"; } >&2; done' ERR

test "$(uname -s)" = Linux
test "$(uname -m)" = aarch64

# The check must prove no network, so it must not have any: a Nix sandbox, or
# a container with no route out where namespaces are unavailable.
if timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/53' 2>/dev/null; then
  echo "SDK consumer check needs an isolated build: the network is reachable" >&2
  exit 1
fi

mkdir consumer consumer/home consumer/config consumer/state consumer/cache
cp -R "$fixture/nagare" "$fixture/invalid" consumer/
chmod -R u+w consumer
cd consumer

export HOME="$PWD/home"
export XDG_CONFIG_HOME="$PWD/config"
export XDG_STATE_HOME="$PWD/state"
export XDG_CACHE_HOME="$PWD/cache"
unset GHC_ENVIRONMENT GHC_PACKAGE_PATH NAGARE_GHC_ENVIRONMENT NAGARE_PLATFORM_ROOT CABAL_DIR CABAL_CONFIG
test -z "$(ls -A "$HOME")"
# The directory has no checkout above it for the loader's ancestor search.
dir="$PWD"
while [ "$dir" != / ]; do
  for marker in release.json cli/nagarectl/nagarectl.cabal cabal.project; do
    if test -e "$dir/$marker"; then
      echo "consumer directory has a checkout marker at $dir/$marker" >&2
      exit 1
    fi
  done
  dir="$(dirname "$dir")"
done
# Neither compiler nor Cabal is visible unless the package supplies it.
if command -v ghc >/dev/null 2>&1 || command -v cabal >/dev/null 2>&1; then
  echo "the check's PATH already has a compiler or Cabal" >&2
  exit 1
fi

"$cli/bin/nagarectl" version --json > version.json
jq -e '.version != null' version.json >/dev/null

# The packaged CLI evaluates the Application.
"$cli/bin/nagarectl" app check -f nagare/Config.hs > check.out 2> check.err
jq -e '.kind == "application" and .name == "sdk-consumer" and .service == true and .workers == 1 and .tasks == 1' check.out >/dev/null

# The published SDK, not the CLI's wrapper, compiles and runs the same file.
mkdir build
"$sdk/bin/ghc" -XGHC2024 -package nagare-dsl -outputdir build -o build/config nagare/Config.hs > ghc.out 2> ghc.err
./build/config | jq -e '.name == "sdk-consumer" and .service != null and (.workers | length) == 1 and (.tasks | length) == 1' >/dev/null

# An invalid Application fails, and does so through the DSL's own validation.
invalid_status=0
"$cli/bin/nagarectl" app check -f invalid/Config.hs > invalid.out 2> invalid.err || invalid_status=$?
test "$invalid_status" -ne 0
test ! -s invalid.out
grep -q "declares image" invalid.err

# Nothing was written outside the consumer directory's own state.
test -z "$(ls -A "$HOME")"

mkdir -p "$out"
jq -n \
  --arg system "$(uname -s)-$(uname -m)" \
  --argjson version "$(cat version.json)" \
  --arg compiler "$("$sdk/bin/ghc" --numeric-version)" \
  --arg compilerTarget "$("$sdk/bin/ghc" --info | grep 'Target platform')" \
  --arg dslPackage "$("$sdk/bin/ghc-pkg" field nagare-dsl id --simple-output)" \
  --arg cli "$cli" \
  --arg sdk "$sdk" \
  --argjson invalidStatus "$invalid_status" \
  --argjson check "$(cat check.out)" \
  '{system: $system, version: $version, compiler: $compiler, compilerTarget: $compilerTarget,
    dslPackage: $dslPackage, packages: {nagarectl: $cli, nagareConfigSdk: $sdk},
    appCheck: $check, invalidConfigExit: $invalidStatus}' > "$out/evidence.json"
cat "$out/evidence.json"
