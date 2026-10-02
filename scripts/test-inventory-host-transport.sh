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
printf 'host transport identity, key refusal, interrupted activation retry, and fresh login: OK\n'
