#!/usr/bin/env bash
# Exercise the production activation function with every external boundary faked.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temporary="$(mktemp -d -t nagare-host-transport-test.XXXXXX)"
trap 'rm -rf "${temporary}"' EXIT
AUDIT_CALLS="${temporary}/calls"
age_key_digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
request='{"plan":{"newClosure":"/nix/store/reviewed","expectedOldClosure":"/nix/store/reviewed","instance":"gce://reviewed-instance","ageKeyDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
instance=disposable
attribute=disposable
destination=deploy@disposable
NAGARE_HOST_AGE_KEY_FILE="${temporary}/key"
SSH_KEY="${temporary}/ssh-key"
touch "${NAGARE_HOST_AGE_KEY_FILE}" "${SSH_KEY}" "${AUDIT_CALLS}"
HOST_PHYSICAL=gce://reviewed-instance
STATUS_DIGEST="${age_key_digest}"
HOST_READY=0

check_host_inputs() { :; }
check_age_key_input() { :; }
physical_identity() { printf '%s' "${HOST_PHYSICAL}"; }
host_ssh() {
  printf 'host_ssh %s\n' "$*" >> "${AUDIT_CALLS}"
  case "$*" in
    *'nagare-host-age-key status'*)
      printf 'age-key\tready\t/var/lib/sops-nix/age-key.txt\t%s\n' "${STATUS_DIGEST}" ;;
    'tailscale ip -4'|'tailscale ip -4 >/dev/null')
      [ "${HOST_READY}" = 1 ] || return 1
      printf '100.116.6.27\n' ;;
    'cat /etc/ssh/ssh_host_ed25519_key.pub')
      printf 'ssh-ed25519 test-host-key\n' ;;
    *) echo "unexpected host command: $*" >&2; return 98 ;;
  esac
}
bash() {
  printf 'send-file %s\n' "$*" >> "${AUDIT_CALLS}"
  [ "$1" = "${script_dir}/iap-ssh.sh" ] && [ "$2" = send-file ] || return 98
  HOST_READY=1
}
ssh() {
  printf 'fresh-ssh %s\n' "$*" >> "${AUDIT_CALLS}"
  printf '/nix/store/reviewed\n'
}
emit_state() { printf '%s %s %s\n' "$1" "$2" "$3"; }

# Source the actual function, not a maintained test copy of its logic.
eval "$(sed -n '/^tailnet_fresh_closure() {/,/^}/p' "${script_dir}/inventory-host-transport.sh")"
eval "$(sed -n '/^credential_receipt_path() {/,/^}/p' "${script_dir}/inventory-host-transport.sh")"
eval "$(sed -n '/^credential_activation_ready() {/,/^}/p' "${script_dir}/inventory-host-transport.sh")"
eval "$(sed -n '/^previous_key_matches() {/,/^}/p' "${script_dir}/inventory-host-transport.sh")"
eval "$(sed -n '/^activate() {/,/^}/p' "${script_dir}/inventory-host-transport.sh")"

HOST_PHYSICAL=gce://replacement
if activate > "${temporary}/replacement.out" 2>&1; then
  echo "replacement VM was accepted" >&2; exit 1
fi
if grep -q 'send-file\|fresh-ssh' "${AUDIT_CALLS}"; then
  echo "replacement VM reached an effect" >&2; exit 1
fi

HOST_PHYSICAL=gce://reviewed-instance
STATUS_DIGEST=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
: > "${AUDIT_CALLS}"
if activate > "${temporary}/wrong-key.out" 2>&1; then
  echo "different installed key was accepted" >&2; exit 1
fi
if grep -q 'send-file\|fresh-ssh' "${AUDIT_CALLS}"; then
  echo "different key reached an effect" >&2; exit 1
fi

STATUS_DIGEST="${age_key_digest}"
HOST_READY=0
: > "${AUDIT_CALLS}"
activate > "${temporary}/recovered.out"
grep -q '^HostTransportCommitted ' "${temporary}/recovered.out"
[ "$(grep -c '^send-file ' "${AUDIT_CALLS}")" -eq 1 ]
[ "$(grep -c '^fresh-ssh ' "${AUDIT_CALLS}")" -eq 1 ]
grep -q -- '-o ControlMaster=no' "${AUDIT_CALLS}"
grep -q -- '-o ControlPath=none' "${AUDIT_CALLS}"

: > "${AUDIT_CALLS}"
tailnet_fresh_closure > "${temporary}/tailnet.out"
grep -q -- '-o ControlMaster=no' "${AUDIT_CALLS}"
grep -q -- '-o ControlPath=none' "${AUDIT_CALLS}"

: > "${AUDIT_CALLS}"
activate > "${temporary}/ready.out"
grep -q '^HostTransportCommitted ' "${temporary}/ready.out"
if grep -q '^send-file ' "${AUDIT_CALLS}"; then
  echo "ready host unnecessarily reactivated" >&2; exit 1
fi
# F93: a host review can carry two activation operations for one closure (an
# update of the system and its declared activation). The first writes the
# credential receipt; the second must find it, so the receipt is keyed by what it
# proves (instance, closures, keys), not by the operation that wrote it.
plan_for() {
  printf '{"plan":{"operation":"%s","inputDigest":"%s","activationId":"%s","version":2,"credentialReceiptRequired":true,"instance":"gce://reviewed-instance","expectedOldClosure":"/nix/store/old","newClosure":"%s","ageKeyDigest":"%s"}}' "$1" "$2" "$1" "$3" "$4"
}
receipt_for() { (request="$1"; credential_receipt_path); }
first="$(receipt_for "$(plan_for op-update 1111 /nix/store/new "${age_key_digest}")")"
second="$(receipt_for "$(plan_for op-declared 2222 /nix/store/new "${age_key_digest}")")"
[ "${first}" = "${second}" ] || { echo "two activations of one review use different credential receipts" >&2; exit 1; }
[ "${first}" != "$(receipt_for "$(plan_for op-update 1111 /nix/store/other "${age_key_digest}")")" ] \
  || { echo "a different closure shares the credential receipt" >&2; exit 1; }
[ "${first}" != "$(receipt_for "$(plan_for op-update 1111 /nix/store/new bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)")" ] \
  || { echo "a different key shares the credential receipt" >&2; exit 1; }
# F121: the host closure builds on the context's builder through a pinned
# tunnel, never on the machine's default builders.
# activate's RETURN trap outlives it here; production calls nothing after it.
trap - RETURN
# shellcheck source=lib/builder.sh
source "${script_dir}/lib/builder.sh"
eval "$(sed -n '/^host_build() {/,/^}/p' "${script_dir}/inventory-host-transport.sh")"
NIX_TRUSTED=true
nix() {
  printf 'nix %s\n' "$*" >> "${AUDIT_CALLS}"
  case "$1" in
    store) printf '{"trusted":%s}\n' "${NIX_TRUSTED}" ;;
    build) printf '/nix/store/host-closure\n' ;;
    *) return 98 ;;
  esac
}
TARGET_PROJECT=labs-project NAGARE_CONTEXT=labs NAGARE_BUILDER_ZONE=us-west1-a NAGARE_BUILDER_INSTANCE=labs-builder
NIX_BUILDER_SSH_KEY="${temporary}/builder-key" NIX_BUILDER_TUNNEL_PORT=28157
NIX_BUILDER_HOST_KEY_B64="$(printf 'ssh-ed25519 fixture-key\n' | base64 | tr -d '\n')"
NAGARE_BUILDER_PROJECT=shared-project
: > "${AUDIT_CALLS}"
if host_build ref > "${temporary}/shared.out" 2>&1; then
  echo "a builder in another project was accepted" >&2; exit 1
fi
if grep -q '^nix ' "${AUDIT_CALLS}"; then
  echo "a builder in another project reached nix" >&2; exit 1
fi
NAGARE_BUILDER_PROJECT=labs-project
NIX_TRUSTED=false
if host_build ref > "${temporary}/untrusted.out" 2>&1; then
  echo "an untrusted daemon was accepted" >&2; exit 1
fi
if grep -q '^nix build' "${AUDIT_CALLS}"; then
  echo "an untrusted daemon reached a build" >&2; exit 1
fi
NIX_TRUSTED=true
: > "${AUDIT_CALLS}"
[ "$(host_build ref)" = /nix/store/host-closure ]
grep -q "^nix build --builders ssh-ng://builder@localhost:28157 x86_64-linux ${NIX_BUILDER_SSH_KEY} .* - ${NIX_BUILDER_HOST_KEY_B64} --no-link --no-update-lock-file --print-out-paths ref$" "${AUDIT_CALLS}"
printf 'host transport identity, key refusal, interrupted activation retry, fresh login, one receipt per reviewed activation, and context-builder host builds: OK\n'
