#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
fixture="$(mktemp -d)"
cleanup() {
  local status="$?"
  if [ "$status" -ne 0 ]; then
    for evidence in dry-run.out switch.out override.out calls.log; do
      if [ -f "$fixture/$evidence" ]; then
        printf '%s\n' "--- $evidence" >&2
        sed -n '1,200p' "$fixture/$evidence" >&2
      fi
    done
  fi
  rm -rf "$fixture"
  exit "$status"
}
trap cleanup EXIT

mkdir -p "$fixture/bin" "$fixture/config/nagare/contexts" "$fixture/home" "$fixture/host"
touch "$fixture/host/flake.nix" "$fixture/host/host.nix"
printf '%s\n' \
  'export CLOUDSDK_CORE_PROJECT=fixture-project' \
  'export NAGARE_INSTANCE_NAME=nagare-01' \
  > "$fixture/config/nagare/contexts/labs.env"
printf '%s\n' \
  'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyForNagareEvaluationOnly operator@example' \
  > "$fixture/operator.pub"

write_executable() {
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
  chmod +x "$path"
}

write_executable "$fixture/bin/nagarectl" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "nagarectl %s\n" "$*" >> "${NAGARE_IDENTITY_LOG:?}"' \
  'case "$*" in' \
  '  "host name") printf "%s\n" "labs-nagare" ;;' \
  '  *) printf "unexpected nagarectl call: %s\n" "$*" >&2; exit 64 ;;' \
  'esac'

write_executable "$fixture/bin/nix" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "nix %s\n" "$*" >> "${NAGARE_IDENTITY_LOG:?}"' \
  'case "$*" in' \
  '  *evaluationFixture*) printf "%s\n" false ;;' \
  '  *authorizedKeys.keys*) printf "%s\n" '\''["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyForNagareEvaluationOnly operator@example"]'\'' ;;' \
  '  "build "*) printf "%s\n" /nix/store/fake-labs-system ;;' \
  '  "copy "*) ;;' \
  '  *) printf "unexpected nix call: %s\n" "$*" >&2; exit 64 ;;' \
  'esac'

write_executable "$fixture/bin/ssh" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "ssh %s\n" "$*" >> "${NAGARE_IDENTITY_LOG:?}"' \
  'case "$*" in' \
  '  *"nagare-safe-activate arm /nix/store/fake-labs-system 600 ") printf "%s\n" "ARMED previous=/nix/store/old-system new=/nix/store/fake-labs-system" ;;' \
  '  *"nagare-safe-activate commit /nix/store/fake-labs-system ") printf "%s\n" "COMMITTED new=/nix/store/fake-labs-system" ;;' \
  '  *"sudo -n true && readlink -f /run/current-system") printf "%s\n" /nix/store/fake-labs-system ;;' \
  'esac'

export PATH="$fixture/bin:$PATH"
export HOME="$fixture/home"
export XDG_CONFIG_HOME="$fixture/config"
export NAGARE_IDENTITY_LOG="$fixture/calls.log"
export NAGARE_CONTEXT=labs
export NAGARE_INSTANCE_NAME=nagare-01
export NAGARE_HOST_FLAKE="$fixture/host"
export NAGARE_PLATFORM_ROOT="$repo_root"
export NAGARE_WORKSPACE_ROOT="$repo_root"
export NAGARE_SSH_PUBLIC_KEY_FILE="$fixture/operator.pub"

touch "$NAGARE_IDENTITY_LOG"
bash "$repo_root/scripts/host-switch.sh" --dry-run > "$fixture/dry-run.out"
grep -q '^GCE instance: nagare-01$' "$fixture/dry-run.out"
grep -q '^attribute: labs-nagare$' "$fixture/dry-run.out"
grep -q '^target host: deploy@labs-nagare$' "$fixture/dry-run.out"

bash "$repo_root/scripts/host-switch.sh" > "$fixture/switch.out"
grep -q 'COMMITTED new=/nix/store/fake-labs-system' "$fixture/switch.out"
grep -q 'nixosConfigurations.labs-nagare' "$NAGARE_IDENTITY_LOG"
grep -q 'deploy@labs-nagare' "$NAGARE_IDENTITY_LOG"
if grep -q 'nixosConfigurations.nagare-01\|deploy@nagare-01' "$NAGARE_IDENTITY_LOG"; then
  echo "host-switch addressed the GCE instance as a Nix or SSH identity" >&2
  cat "$NAGARE_IDENTITY_LOG" >&2
  exit 1
fi

: > "$NAGARE_IDENTITY_LOG"
NAGARE_HOST_ATTR=override-attr NAGARE_SSH_HOST=override-host \
  bash "$repo_root/scripts/host-switch.sh" --dry-run > "$fixture/override.out"
grep -q '^GCE instance: nagare-01$' "$fixture/override.out"
grep -q '^attribute: override-attr$' "$fixture/override.out"
grep -q '^target host: deploy@override-host$' "$fixture/override.out"

printf '%s\n' \
  'GCE instance: nagare-01' \
  'attribute: labs-nagare' \
  'target host: deploy@labs-nagare' \
  'wrong-host calls: 0'
