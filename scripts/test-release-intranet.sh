#!/usr/bin/env bash
# EP-210 M5: scripts/release-intranet.sh and release-publish's intranet precondition against a
# throwaway operator repository and fake direnv, nagarectl, nix and curl. Every refusal writes
# no record and commits nothing. Run by scripts/test-release.sh.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
version=9.8.7
rev=0123456789abcdef0123456789abcdef01234567
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export HOME="$test_root/home"
mkdir -p "$HOME"

# A fresh operator repository, fake state and candidate run under $test_root/$1.
fixture() {
  root="$test_root/$1"
  operator="$root/operator"
  state="$root/state"
  run="$root/run"
  bin="$root/bin"
  mkdir -p "$operator/hosts/intranet" "$operator/contexts" "$operator/apps" "$state" "$run" "$bin"
  printf '{\n  inputs.nagare.url = "github:shinzui/nagare/v9.8.6";\n}\n' > "$operator/flake.nix"
  printf '{"nodes":{"nagare":{"locked":{"rev":"old"}}}}\n' > "$operator/flake.lock"
  printf 'host flake\n' > "$operator/hosts/intranet/flake.nix"
  printf '{}\n' > "$operator/hosts/intranet/flake.lock"
  printf 'export NAGARE_PLATFORM_VERSION=9.8.6\n' > "$operator/contexts/intranet.env"
  printf 'config\n' > "$operator/apps/Databases.hs"
  git -C "$operator" init -q
  git -C "$operator" config user.name 'Nagare release test'
  git -C "$operator" config user.email 'release-test@example.invalid'
  git -C "$operator" add .
  git -C "$operator" commit -qm 'chore: seed operator fixture'
  # The operator's own work in progress, staged; no release commit may take it.
  printf 'edited config\n' > "$operator/apps/Databases.hs"
  git -C "$operator" add apps/Databases.hs
  jq -n --arg version "$version" --arg revision "$rev" '{version: $version, revision: $revision, previous: "9.8.6"}' > "$run/candidate.json"

  at() { jq -n --arg v "$1" --arg r "$2" '{version: $v, revision: $r, payloadSchema: 1}'; }
  jq -n --argjson at "$(at "$version" "$rev")" --argjson old "$(at 9.8.6 old)" \
    '{compatibility: "minor-upgrade-required", identities: {cli: $at, payload: $at, host: $old, cluster: $old, context: $old}}' > "$state/platform.json"
  jq -n --argjson at "$(at "$version" "$rev")" \
    '{compatibility: "exact", identities: {cli: $at, payload: $at, host: $at, cluster: $at, context: ($at | .revision = null)}}' > "$state/platform-after.json"
  scope='{"scope": {"kind": "platform", "name": "auth"}, "revision": {"generation": 2, "digest": "d"}}'
  jq -n --argjson s "$scope" '{activeTransaction: null, accepted: [$s], converged: [$s], findings: []}' > "$state/inventory.json"
  jq -n --arg v "$version" --arg r "$rev" '{version: $v, revision: $r}' > "$state/version.json"
  printf '2\n' > "$state/stages"
  printf '302 https://auth.example.test/login?return_to=x\n' > "$state/curl"

  cat > "$bin/direnv" <<'EOF'
#!/usr/bin/env bash
[ "$1" = exec ] || exit 2
shift 2
exec "$@"
EOF
  printf '#!/bin/sh\nexit 0\n' > "$bin/gcloud"
  cat > "$bin/curl" <<EOF
#!/bin/sh
cat "$state/curl"
EOF
  cat > "$bin/nix" <<EOF
#!/bin/sh
[ "\$1 \$2 \$3" = "flake update nagare" ] || exit 2
url="\$(sed -n 's/.*inputs.nagare.url = "\\(.*\\)";/\\1/p' flake.nix)"
jq -n --arg r "\$(cat "$state/lock-rev" 2>/dev/null || echo "$rev")" --arg u "\$url" '{nodes: {nagare: {locked: {rev: \$r}, original: {url: \$u}}}}' > flake.lock
EOF
  cat > "$bin/nagarectl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
state="$state"
operator="$operator"
[ "\$1" = --context ] && shift 2
case "\$*" in
  "version --json") cat "\$state/version.json" ;;
  "inventory status --json") cat "\$state/inventory.json" ;;
  "platform status --json") cat "\$state/platform.json" ;;
  "platform transition plan --out "*)
    out="\$5"
    if [ -f "\$state/compile-error" ]; then echo "apps/Databases.hs:3:5: error: missing field privileges" >&2; exit 1; fi
    mkdir -p "\$out"
    ops='[]'; [ "\$(cat "\$state/stages")" -gt 0 ] && ops='[{"action": {"tag": "VerifyResource"}}]'
    jq -n --argjson ops "\$ops" '{operations: \$ops, baseRevisions: [], desiredRevisions: []}' > "\$out/review.json" ;;
  "inventory apply "*" --yes")
    if [ -f "\$state/ambiguous" ]; then rm "\$state/ambiguous"; echo "ambiguous tx-ab12 at op-1"; exit 1; fi
    echo \$((\$(cat "\$state/stages") - 1)) > "\$state/stages"
    echo "# reviewed host inputs" >> "\$operator/hosts/intranet/flake.nix"
    echo "converged tx-cd34" ;;
  "inventory resume tx-ab12 --yes")
    echo \$((\$(cat "\$state/stages") - 1)) > "\$state/stages"; echo "converged tx-ab12" ;;
  "platform transition commit --yes")
    cp "\$state/platform-after.json" "\$state/platform.json"
    echo "export NAGARE_PLATFORM_VERSION=$version" > "\$operator/contexts/intranet.env"
    echo "committed" ;;
  *) echo "fake nagarectl: unexpected \$*" >&2; exit 2 ;;
esac
EOF
  # A Linux build sandbox has no /usr/bin/env.
  for tool in "$bin"/*; do sed -i.bak "1s|.*|#!$BASH|" "$tool" && rm "$tool.bak"; done
  chmod +x "$bin"/*
}

intranet() { # extra args...
  PATH="$bin:$PATH" NAGARE_RELEASE_OPERATOR_REPO="$operator" \
    NAGARE_RELEASE_PROTECTED_URL=https://protected-hello.example.test/ \
    bash "$repo_root/scripts/release-intranet.sh" "$version" --run "$run" "$@"
}

# A refusal: non-zero, the expected words, no record, no commit, the operator's staging intact.
refuses() { # label words
  local label="$1" words="$2" head
  head="$(git -C "$operator" rev-parse HEAD)"
  if intranet > "$root/$label.out" 2> "$root/$label.err"; then
    printf 'expected refusal: %s\n' "$label" >&2; exit 1
  fi
  grep -Fq "$words" "$root/$label.err" || { printf '%s: expected "%s" in:\n' "$label" "$words" >&2; cat "$root/$label.err" >&2; exit 1; }
  [[ ! -e "$run/intranet.json" ]] || { printf '%s wrote a record\n' "$label" >&2; exit 1; }
  [[ "$(git -C "$operator" rev-parse HEAD)" == "$head" ]] || { printf '%s committed\n' "$label" >&2; exit 1; }
  [[ "$(git -C "$operator" diff --cached --name-only)" == apps/Databases.hs ]] || { printf '%s changed the staging\n' "$label" >&2; exit 1; }
}

# --- the candidate, with an apply that stops ambiguous once ---
fixture success
touch "$state/ambiguous"
intranet > "$root/out" 2>&1 || { cat "$root/out" >&2; exit 1; }
jq -e --arg v "$version" --arg r "$rev" '.version == $v and .revision == $r and .context == "intranet"
  and .status.compatibility == "exact" and .protected.status == 302 and .inventory.converged' "$run/intranet.json" >/dev/null
grep -q 'resuming tx-ab12 once' "$root/out"
[[ "$(git -C "$operator" log -1 --format=%s)" == "feat(nagare): upgrade the intranet to the v$version candidate" ]]
[[ "$(git -C "$operator" show --name-only --format= HEAD | sort | tr '\n' ' ')" == "contexts/intranet.env flake.lock flake.nix hosts/intranet/flake.nix " ]]
grep -Fq "inputs.nagare.url = \"github:shinzui/nagare/$rev\";" "$operator/flake.nix"
[[ "$(git -C "$operator" diff --cached --name-only)" == apps/Databases.hs ]]
# A rerun plans no operations, commits nothing and rewrites the record.
head="$(git -C "$operator" rev-parse HEAD)"
intranet > "$root/rerun.out" 2>&1 || { cat "$root/rerun.out" >&2; exit 1; }
[[ "$(git -C "$operator" rev-parse HEAD)" == "$head" ]]
grep -q 'stage 1: 0 operations' "$root/rerun.out"
# --- the published tag: flake.nix and flake.lock alone ---
intranet --pin-tag > "$root/tag.out" 2>&1 || { cat "$root/tag.out" >&2; exit 1; }
[[ "$(git -C "$operator" log -1 --format=%s)" == "chore(nagare): pin the intranet to the published v$version tag" ]]
[[ "$(git -C "$operator" show --name-only --format= HEAD | sort | tr '\n' ' ')" == "flake.lock flake.nix " ]]
grep -Fq "inputs.nagare.url = \"github:shinzui/nagare/v$version\";" "$operator/flake.nix"
[[ "$(git -C "$operator" diff --cached --name-only)" == apps/Databases.hs ]]

# --- release-publish refuses before signing without this run's intranet record ---
publish_repo="$test_root/publish-repo"
git init -q "$publish_repo"
mkdir -p "$test_root/xdg/nagare/releases/v$version"
ln -s "$run" "$test_root/xdg/nagare/releases/v$version/latest"
touch "$test_root/key.pub"
publish() {
  (cd "$publish_repo" && XDG_STATE_HOME="$test_root/xdg" NAGARE_RELEASE_SIGNING_KEY="$test_root/key.pub" \
    bash "$repo_root/scripts/release-publish.sh" "$version") > "$test_root/publish.out" 2>&1 && return 1
  grep -Fq "$1" "$test_root/publish.out" || { cat "$test_root/publish.out" >&2; return 1; }
}
publish 'SHA256SUMS does not verify'
jq '.revision = "another"' "$run/intranet.json" > "$run/foreign.json"
mv "$run/intranet.json" "$run/valid.json"
mv "$run/foreign.json" "$run/intranet.json"
publish "no intranet record for $version at $rev"
rm "$run/intranet.json"
publish "no intranet record for $version at $rev"

# --- refusals ---
fixture dirty-pin
printf 'local edit\n' >> "$operator/flake.lock"
refuses dirty-pin 'the pin files have uncommitted changes'

fixture wrong-cli
jq '.revision = "another"' "$state/version.json" > "$state/v.tmp" && mv "$state/v.tmp" "$state/version.json"
refuses wrong-cli "nagarectl is not $version at $rev"

fixture wrong-lock
printf 'another\n' > "$state/lock-rev"
refuses wrong-lock "does not resolve github:shinzui/nagare/$rev to $rev"

fixture active-transaction
jq '.activeTransaction = "tx-open"' "$state/inventory.json" > "$state/i.tmp" && mv "$state/i.tmp" "$state/inventory.json"
refuses active-transaction 'has an active transaction'

fixture compile-error
touch "$state/compile-error"
refuses compile-error 'missing field privileges'

fixture host-skew
jq '.identities.host.revision = "another"' "$state/platform-after.json" > "$state/p.tmp" && mv "$state/p.tmp" "$state/platform-after.json"
refuses host-skew "platform status is not exact on $version at $rev"

fixture unconverged
jq '.converged = []' "$state/inventory.json" > "$state/i.tmp" && mv "$state/i.tmp" "$state/inventory.json"
refuses unconverged 'an accepted scope that has not converged'

fixture unprotected
printf '200 \n' > "$state/curl"
refuses unprotected 'answered 200'

printf 'release intranet tests passed\n'
