#!/usr/bin/env bash
# A cloud deployer observes and publishes app images in its delegation's own
# repository of the context's project; an operator stays on the platform
# repository. gcloud and skopeo are recording fakes.
set -euo pipefail

work="$(mktemp -d -t nagare-deployer-transport.XXXXXX)"
trap 'rm -rf "$work"' EXIT
script="$PWD/scripts/inventory-artifact-transport.sh"
mkdir -p "$work/bin" "$work/config/nagare/contexts"
calls="$work/calls"

cat >"$work/bin/gcloud" <<EOF
#!$(command -v bash)
case "\$*" in
  "auth print-access-token") echo token ;;
  "config get-value project") echo proj ;;
  *) echo "unexpected gcloud \$*" >&2; exit 1 ;;
esac
EOF
cat >"$work/bin/skopeo" <<EOF
#!$(command -v bash)
echo "skopeo \$*" >>"$calls"
case " \$* " in
  *" login "*) cat >/dev/null ;;
  *" inspect "*docker-archive:*) echo "sha256:\$FAKE_DIGEST" ;;
  *" inspect "*docker://*)
    [ -e "$work/registry" ] && echo "sha256:\$FAKE_DIGEST" || { echo "manifest unknown" >&2; exit 1; } ;;
  *" copy "*) touch "$work/registry" ;;
esac
EOF
chmod +x "$work/bin/gcloud" "$work/bin/skopeo"
cat >"$work/config/nagare/contexts/deployer-test.env" <<EOF
export NAGARE_MODE=cloud
export CLOUDSDK_CORE_PROJECT=proj
export NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev
export NAGARE_ARTIFACT_REGISTRY_ID=nagare
export NAGARE_BASE_DOMAIN=example.com
EOF
printf 'archive' >"$work/image.tar"
archive_digest="$(sha256sum "$work/image.tar" 2>/dev/null || shasum -a 256 "$work/image.tar")"
archive_digest="${archive_digest%% *}"
digest="$(printf 'c%.0s' {1..64})"

# run ACTION DESTINATION [VAR=value...]
run() {
  local action="$1" destination="$2"
  shift 2
  : >"$calls"
  rm -f "$work/registry"
  jq -nc --arg dest "$destination" --arg d "$digest" --arg s "$archive_digest" --arg a "$work/image.tar" \
    '{version:1,resource:"fixture",kind:"OciImageArtifact",destination:$dest,expectedDigest:$d,specDigest:$s,archive:$a,
      plan:{version:1,resource:"fixture",kind:"OciImageArtifact",destination:$dest,expectedDigest:$d,sourceDigest:$s}}' |
    env -i PATH="$work/bin:$PATH" HOME="$work" TMPDIR="$work" XDG_CONFIG_HOME="$work/config" \
      XDG_STATE_HOME="$work/state" NAGARE_CONTEXT=deployer-test NAGARE_INVENTORY_ADAPTER_CHILD=artifact \
      FAKE_DIGEST="$digest" "$@" bash "$script" "$action" >"$work/out" 2>"$work/err"
}

tag() { jq -r .tag "$work/out"; }
fail() { echo "$1" >&2; cat "$work/out" "$work/err" >&2; exit 1; }

own=us-west1-docker.pkg.dev/proj/kotei-ci/site:kotei-1

run observe "$own" NAGARE_DEPLOYER=kotei-ci || fail "deployer observe of its repository failed"
[ "$(tag)" = TransportMissing ] || fail "deployer observe of its repository is not a confirmed absence"

run observe "$own" || fail "operator observe failed"
[ "$(tag)" = TransportOwnershipMismatch ] || fail "operator observed outside the platform repository"

run observe us-west1-docker.pkg.dev/other/kotei-ci/site:kotei-1 NAGARE_DEPLOYER=kotei-ci || fail "deployer observe of another project failed"
[ "$(tag)" = TransportOwnershipMismatch ] || fail "deployer observed outside the context's project"

run publish "$own" NAGARE_DEPLOYER=kotei-ci || fail "deployer publish to its repository failed"
[ "$(tag)" = TransportPresent ] || fail "deployer publish did not observe the published image"
grep -q "copy .*docker://$own" "$calls" || fail "deployer publish did not copy to its repository"

if run publish "$own"; then fail "operator published outside the platform repository"; fi
grep -q 'OCI destination differs from the selected project' "$work/err" || fail "operator publish refused for another reason"
! grep -q ' copy ' "$calls" || fail "operator publish reached the registry"

printf '%s\n' 'deployer artifact transport passed'
