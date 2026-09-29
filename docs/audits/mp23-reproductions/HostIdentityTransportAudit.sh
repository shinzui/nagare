#!/usr/bin/env bash
set -euo pipefail
age_key_digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
request='{"plan":{"newClosure":"reviewed-closure","expectedOldClosure":"reviewed-closure","instance":"gce://reviewed-instance","ageKeyDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
instance=disposable
script_dir=/nonexistent
NAGARE_HOST_AGE_KEY_FILE=/nonexistent
check_host_inputs() { :; }
check_age_key_input() { :; }
physical_identity() { printf 'gce://replacement'; }
host_ssh() {
  printf '%s\n' "$*" >> "$AUDIT_CALLS"
  case "$*" in
    *'nagare-host-age-key status'*) printf 'age-key\tready\t/var/lib/sops-nix/age-key.txt\t%s\n' "$age_key_digest" ;;
    'tailscale ip -4') return 1 ;;
    *) printf 'unexpected call\n' >&2; return 98 ;;
  esac
}
bash() { printf 'REACTIVATION %s\n' "$*" >> "$AUDIT_CALLS"; return 99; }

activate() {
  local physical new old output receipt closure proof key_status remote_digest tailnet_ip known_hosts host_key ssh_options
  check_host_inputs
  check_age_key_input
  physical="$(physical_identity)"
  new="$(jq -er '.plan.newClosure' <<<"${request}")"
  old="$(jq -er '.plan.expectedOldClosure' <<<"${request}")"
  [ "${physical}" = "$(jq -er '.plan.instance' <<<"${request}")" ] || {
    echo "host physical instance differs from reviewed activation" >&2; return 2;
  }
  [ "$(jq -r '.plan.ageKeyDigest // empty' <<<"${request}")" = "${age_key_digest}" ] || {
    echo "reviewed host age-key digest changed" >&2; return 2;
  }
  if [ -n "${age_key_digest}" ]; then
    key_status="$(host_ssh 'sudo /run/current-system/sw/bin/nagare-host-age-key status')"
    remote_digest="$(awk -F '\t' '$1 == "age-key" && $2 == "ready" {print $4}' <<<"${key_status}")"
    if [ "${remote_digest}" != "${age_key_digest}" ]; then
      [ -z "${remote_digest}" ] && grep -q $'^age-key\tmissing\t' <<<"${key_status}" || {
        echo "host has a different or invalid age key; refusing replacement" >&2; return 2;
      }
    fi
    if [ "${remote_digest}" != "${age_key_digest}" ] ||
      ! host_ssh 'tailscale ip -4 >/dev/null' >/dev/null 2>&1; then
      # The helper accepts an identical installed key and reruns sops/Tailscale
      # activation. This closes an interrupted install-after-write window.
      bash "${script_dir}/iap-ssh.sh" send-file "${instance}" "${NAGARE_HOST_AGE_KEY_FILE}" -- \
        sudo -- /run/current-system/sw/bin/nagare-host-age-key install --sha256 "${age_key_digest}"
    fi
    key_status="$(host_ssh 'sudo /run/current-system/sw/bin/nagare-host-age-key status')"
    grep -Fq $'age-key\tready\t/var/lib/sops-nix/age-key.txt\t'"${age_key_digest}" <<<"${key_status}" || {
      echo "host age-key placement lacks a matching ready receipt" >&2; return 1;
    }
    tailnet_ip="$(host_ssh 'tailscale ip -4' | tail -n 1)"
    [[ "${tailnet_ip}" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
      echo "host has no Tailscale IPv4 address after age-key placement" >&2; return 1;
    }
    host_key="$(host_ssh 'cat /etc/ssh/ssh_host_ed25519_key.pub' | awk '$1 == "ssh-ed25519" {print $1 " " $2; exit}')"
    [ -n "${host_key}" ] || { echo "host has no IAP-observed SSH host key" >&2; return 1; }
    known_hosts="$(mktemp -t nagare-host-known.XXXXXX)"
    trap 'rm -f "${known_hosts}"' RETURN
    printf '%s %s\n' "${tailnet_ip}" "${host_key}" > "${known_hosts}"
    ssh_options="-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -o ControlMaster=no -o ControlPath=none -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${known_hosts} -o GlobalKnownHostsFile=/dev/null -i ${SSH_KEY:?SSH_KEY is required for reviewed host activation}"
    closure="$(ssh ${ssh_options} "deploy@${tailnet_ip}" 'sudo -n true && readlink -f /run/current-system' | tail -n 1)"
    [ "${closure}" = "${old}" ] || {
      echo "fresh Tailnet login found a closure outside the reviewed old state" >&2; return 1;
    }
    if [ "${old}" = "${new}" ]; then
      receipt="$(printf 'nagare-host-activation\tcommitted\t%s\tfresh-login' "${new}")"
      proof="$(printf '%s' "${receipt}" | shasum -a 256 | awk '{print $1}')"
      emit_state HostTransportCommitted "${physical}" "${new}" "${proof}"
      return
    fi
    export NIX_SSHOPTS="${ssh_options}"
  fi
  output="$(NAGARE_HOST_ATTR="${attribute}" NAGARE_SSH_HOST="${tailnet_ip:-${destination#*@}}" \
    NAGARE_HOST_PREPARED_CLOSURE="${new}" NAGARE_HOST_EXPECTED_OLD_CLOSURE="${old}" \
    bash "${script_dir}/host-switch.sh")"
  printf '%s\n' "${output}" >&2
  receipt="$(grep '^nagare-host-activation[[:space:]]' <<<"${output}" | tail -n 1)"
  closure="$(awk -F '\t' '$1 == "nagare-host-activation" && $2 == "committed" && $4 == "fresh-login" { print $3 }' <<<"${receipt}")"
  [ "${closure}" = "${new}" ] || { echo "host activation did not return the reviewed committed closure" >&2; return 1; }
  proof="$(printf '%s' "${receipt}" | shasum -a 256 | awk '{print $1}')"
  emit_state HostTransportCommitted "${physical}" "${closure}" "${proof}"
}

activate
