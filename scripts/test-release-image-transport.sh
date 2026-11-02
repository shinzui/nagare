#!/usr/bin/env bash
# EP-237: the artifact transport's release image path, with nix and skopeo as
# recording fakes. A cache miss and a wrong layout stop with exit 3 before any
# registry call; a present layout is not fetched; publication copies by digest.
set -euo pipefail

work="$(mktemp -d -t nagare-release-image-transport.XXXXXX)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
script="$PWD/scripts/inventory-artifact-transport.sh"
expected="$(printf 'a%.0s' {1..64})"
hash="$(printf 'b%.0s' {1..32})"
store_path="/nix/store/$hash-nagare-en-oci"
destination="127.0.0.1:5001/en:sha256-$expected"
calls="$work/calls"
mkdir -p "$work/bin" "$work/config/nagare/contexts"

cat >"$work/bin/nix" <<EOF
#!$(command -v bash)
echo "nix \$*" >>"$calls"
[ -z "\${FAKE_CACHE_MISS:-}" ] || { echo "error: path is not valid" >&2; exit 1; }
while [ \$# -gt 1 ]; do [ "\$1" = --to ] && to="\$2"; shift; done
mkdir -p "\$to\$1" && touch "\$to\$1/index.json"
EOF
cat >"$work/bin/skopeo" <<EOF
#!$(command -v bash)
echo "skopeo \$*" >>"$calls"
case " \$* " in
  *" inspect "*oci:*) echo "\${FAKE_MANIFEST:-sha256:$expected}" ;;
  *" inspect "*docker://*)
    [ -e "$work/registry" ] && echo "sha256:$expected" || { echo "manifest unknown" >&2; exit 1; } ;;
  *" copy "*) touch "$work/registry" ;;
esac
EOF
chmod +x "$work/bin/nix" "$work/bin/skopeo"
cat >"$work/config/nagare/contexts/transport-test.env" <<EOF
export NAGARE_MODE=local
export NAGARE_REGISTRY_HOST=127.0.0.1:5001
export NAGARE_BASE_DOMAIN=localhost
EOF

request="$(jq -nc --arg d "$expected" --arg dest "$destination" --arg a "$store_path" \
  '{version:1,resource:"fixture",kind:"OciImageArtifact",destination:$dest,expectedDigest:$d,specDigest:$d,archive:$a,
    plan:{version:1,resource:"fixture",kind:"OciImageArtifact",destination:$dest,expectedDigest:$d,sourceDigest:$d}}')"

run() {
  : >"$calls"
  rm -f "$work/registry"
  printf '%s' "$request" | env PATH="$work/bin:$PATH" TMPDIR="$work" \
    XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state" NAGARE_CONTEXT=transport-test \
    NAGARE_INVENTORY_ADAPTER_CHILD=artifact \
    NAGARE_RELEASE_IMAGE_CACHE=https://cache.example.test "$@" \
    bash "$script" publish >"$work/out" 2>"$work/err"
}

expect_refused() {
  local label="$1" message="$2"
  shift 2
  local code=0
  run "$@" || code=$?
  [ "$code" = 3 ] || { echo "$label: exit $code, not 3" >&2; cat "$work/err" >&2; exit 1; }
  grep -q "$message" "$work/err" || { echo "$label: no message '$message'" >&2; cat "$work/err" >&2; exit 1; }
  if grep -Eq 'skopeo.* copy |docker://' "$calls"; then
    echo "$label: reached the registry" >&2
    cat "$calls" >&2
    exit 1
  fi
}

expect_refused "a cache miss" "could not be fetched" FAKE_CACHE_MISS=1
expect_refused "a wrong layout" "not the reviewed" FAKE_MANIFEST="sha256:$(printf 'c%.0s' {1..64})"

run || { echo "publication failed" >&2; cat "$work/err" >&2; exit 1; }
grep -q "^nix --extra-experimental-features nix-command copy --no-check-sigs --from https://cache.example.test --to .* $store_path\$" "$calls" \
  || { echo "the layout was not fetched into a private store" >&2; cat "$calls" >&2; exit 1; }
grep -Eq "skopeo .*copy --preserve-digests .*oci:.*$store_path docker://$destination" "$calls" \
  || { echo "the layout was not copied by digest" >&2; cat "$calls" >&2; exit 1; }
jq -e --arg d "$expected" '.tag == "TransportPresent" and .contents[1] == $d' "$work/out" >/dev/null \
  || { echo "publication did not report the digest" >&2; cat "$work/out" >&2; exit 1; }
if command ls "$work"/nagare-release-image.* >/dev/null 2>&1; then
  echo "the private store was left behind" >&2
  exit 1
fi

printf '%s\n' 'release image transport passed'
