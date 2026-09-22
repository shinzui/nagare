#!/usr/bin/env bash
set -euo pipefail

repo_root="$(pwd)"
work="$(mktemp -d -t nagare-upload-images.XXXXXX)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/config/nagare/contexts" "$work/state" "$work/host" "$work/store/image"
touch "$work/host/flake.nix" "$work/host/host.nix"
printf 'fixture\n' | gzip >"$work/store/image/nagare.raw.tar.gz"

cat >"$work/config/nagare/contexts/labs.env" <<'EOF'
export CLOUDSDK_CORE_PROJECT='labs-project'
export CLOUDSDK_COMPUTE_REGION='us-west1'
export CLOUDSDK_COMPUTE_ZONE='us-west1-a'
export NAGARE_MODE='cloud'
export NAGARE_REGISTRY_HOST='us-west1-docker.pkg.dev'
export NAGARE_ARTIFACT_REGISTRY_ID='nagare'
export NAGARE_BASE_DOMAIN='apps.example.test'
EOF

sed -e "s|@BASH@|$(command -v bash)|g" >"$work/bin/nix" <<'EOF'
#!@BASH@
set -eu
printf 'nix NIX_SSHOPTS=%s argv=%s\n' "${NIX_SSHOPTS:-}" "$*" >>"$NAGARE_TEST_LOG"
if [ "${1:-}" = config ]; then
  printf '%s\n' 'system = aarch64-darwin'
elif [ "${1:-}" = build ]; then
  printf '%s\n' "$NAGARE_TEST_STORE_PATH"
else
  exit 2
fi
EOF

sed -e "s|@BASH@|$(command -v bash)|g" >"$work/bin/pulumi" <<'EOF'
#!@BASH@
set -eu
printf 'pulumi %s\n' "$*" >>"$NAGARE_TEST_LOG"
case " $* " in
  *" config get imageBucket "*) printf '%s\n' 'nagare-test-bucket' ;;
esac
EOF

sed -e "s|@BASH@|$(command -v bash)|g" >"$work/bin/gsutil" <<'EOF'
#!@BASH@
set -eu
printf 'gsutil %s\n' "$*" >>"$NAGARE_TEST_LOG"
if [ "${1:-}" = -q ] && [ "${2:-}" = stat ]; then
  exit 1
fi
EOF

sed -e "s|@BASH@|$(command -v bash)|g" >"$work/bin/gcloud" <<'EOF'
#!@BASH@
set -eu
printf 'gcloud %s\n' "$*" >>"$NAGARE_TEST_LOG"
case " $* " in
  *" storage buckets describe "*) printf '%s\n' 123 ;;
  *" projects describe "*) printf '%s\n' 123 ;;
  *" compute images describe "*" --format=value(name) "*) exit 1 ;;
  *" compute images describe "*" --format=value(selfLink) "*)
    printf '%s\n' 'https://www.googleapis.com/compute/v1/projects/labs-project/global/images/nagare-image-fixture'
    ;;
esac
EOF

sed -e "s|@BASH@|$(command -v bash)|g" >"$work/bin/ssh" <<'EOF'
#!@BASH@
echo "unexpected ssh fallback: $*" >&2
exit 97
EOF

chmod +x "$work/bin/"*
: >"$work/tools.log"

unset CLOUDSDK_CORE_PROJECT CLOUDSDK_COMPUTE_REGION CLOUDSDK_COMPUTE_ZONE
unset NAGARE_BUILDER_PROJECT NAGARE_BUILDER_ZONE NAGARE_BUILDER_INSTANCE
export PATH="$work/bin:$PATH"
export XDG_CONFIG_HOME="$work/config"
export XDG_STATE_HOME="$work/state"
export NAGARE_CONTEXT=labs
export NAGARE_WORKSPACE_ROOT="$repo_root"
export NAGARE_HOST_FLAKE="$work/host"
export NAGARE_TEST_LOG="$work/tools.log"
export NAGARE_TEST_STORE_PATH="$work/store/image"

if NAGARE_INVENTORY_TRANSACTION=tx-test NAGARE_INVENTORY_ADAPTER_CHILD=host \
  bash scripts/upload-images.sh --dry-run >"$work/reentry.out" 2>"$work/reentry.err"; then
  echo "upload-images accepted the wrong inventory adapter child" >&2
  exit 1
fi
grep -q 'requires the artifact adapter child marker' "$work/reentry.err"

NAGARE_INVENTORY_TRANSACTION=tx-test NAGARE_INVENTORY_ADAPTER_CHILD=artifact \
  bash scripts/upload-images.sh --dry-run >"$work/artifact-child.out"
grep -q '^context: labs$' "$work/artifact-child.out"

same_output="$(bash scripts/upload-images.sh --dry-run)"
grep -q '^context: labs$' <<<"$same_output"
grep -q '^local system: aarch64-darwin$' <<<"$same_output"
grep -q '^target system: x86_64-linux$' <<<"$same_output"
grep -q '^builder URI: ssh-ng://builder@nagare-builder-labs$' <<<"$same_output"
grep -q '^builder project: labs-project$' <<<"$same_output"
grep -q '^builder zone: us-west1-a$' <<<"$same_output"
grep -q '^builder instance: nix-builder-x86$' <<<"$same_output"
grep -q '^shared builder exception: no$' <<<"$same_output"

builder_dir="$work/state/nagare/labs/nix-builder"
test "$(stat -c '%a' "$builder_dir")" = 700
test "$(stat -c '%a' "$builder_dir/ssh_config")" = 600
test "$(stat -c '%a' "$builder_dir/builders")" = 600
grep -q 'ProxyCommand.*"labs-project".*"us-west1-a".*"nix-builder-x86"' "$builder_dir/ssh_config"
grep -q '^ssh-ng://builder@nagare-builder-labs x86_64-linux ' "$builder_dir/builders"

if NAGARE_BUILDER_PROJECT=shared-project bash scripts/upload-images.sh --dry-run \
  >"$work/foreign.out" 2>"$work/foreign.err"; then
  echo "foreign builder unexpectedly passed without acknowledgement" >&2
  exit 1
fi
grep -q "repeat with --allow-shared-builder 'shared-project'" "$work/foreign.err"

shared_output="$(NAGARE_BUILDER_PROJECT=shared-project \
  bash scripts/upload-images.sh --allow-shared-builder shared-project --dry-run)"
grep -q '^builder project: shared-project$' <<<"$shared_output"
grep -q '^shared builder exception: yes (shared-project)$' <<<"$shared_output"
grep -q 'ProxyCommand.*"shared-project".*"us-west1-a".*"nix-builder-x86"' "$builder_dir/ssh_config"

: >"$work/tools.log"
bash scripts/upload-images.sh >"$work/real.out" 2>"$work/real.err"
grep -q '^builder project: labs-project$' "$work/real.err"
grep -q 'nix NIX_SSHOPTS=-F.*/nagare/labs/nix-builder/ssh_config argv=build --builders ssh-ng://builder@nagare-builder-labs x86_64-linux /etc/nix/builder_ed25519 4 1 big-parallel,benchmark --print-out-paths --no-link .#packages.x86_64-linux.nagare-image$' "$work/tools.log"
if grep -q '/etc/nix/machines' "$work/tools.log"; then
  echo "ambient Nix builders leaked into the host-image invocation" >&2
  exit 1
fi
if grep -q 'gsutil mb' "$work/tools.log"; then
  echo "upload-images.sh attempted to claim the inventory-owned image bucket" >&2
  exit 1
fi

printf '%s\n' 'upload-images builder confinement tests passed'
