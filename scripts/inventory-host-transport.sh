#!/usr/bin/env bash
# Narrow typed transport for the host inventory adapter.
set -euo pipefail

if [ "${NAGARE_INVENTORY_ADAPTER_CHILD:-}" != host ]; then
  echo "host transport requires the host adapter child marker" >&2
  exit 2
fi

action="${1:-}"
case "${action}" in observe|prepare|inspect|activate) ;; *) echo "usage: $0 {observe|prepare|inspect|activate}" >&2; exit 2 ;; esac

request="$(cat)"
version="$(jq -er '.version' <<<"${request}")"
context="$(jq -er '.context' <<<"${request}")"
attribute="$(jq -er '.hostAttribute' <<<"${request}")"
project="$(jq -er '.project' <<<"${request}")"
zone="$(jq -er '.zone' <<<"${request}")"
instance="$(jq -er '.instanceName' <<<"${request}")"
destination="$(jq -er '.destination' <<<"${request}")"
[ "${version}" = 1 ] || { echo "unsupported host transport version" >&2; exit 2; }
for value in "${context}" "${attribute}" "${project}" "${zone}" "${instance}" "${destination}"; do
  case "${value}" in ""|*[!A-Za-z0-9._@:-]*) echo "invalid host transport identity: ${value}" >&2; exit 2 ;; esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/target.sh
source "${script_dir}/lib/target.sh"
[ "${context}" = "${NAGARE_CONTEXT}" ] || { echo "reviewed host context differs from active context" >&2; exit 2; }
[ "${project}" = "${TARGET_PROJECT}" ] || { echo "reviewed host project differs from active project" >&2; exit 2; }
[ "${zone}" = "${TARGET_ZONE}" ] || { echo "reviewed host zone differs from active zone" >&2; exit 2; }
[ "${instance}" = "${NAGARE_INSTANCE_NAME}" ] || { echo "reviewed host instance differs from active instance" >&2; exit 2; }

absence_digest() {
  local value
  value="$(printf 'host-absence:%s:%s:%s' "${project}" "${zone}" "${instance}" | shasum -a 256 | awk '{print $1}')"
  printf 'sha256:%s' "${value}"
}

physical_identity() {
  local output identifier
  if ! output="$(gcloud --project="${project}" compute instances describe "${instance}" --zone="${zone}" --format='value(id)' 2>&1)"; then
    if grep -Eqi 'not found|was not found' <<<"${output}"; then return 3; fi
    printf '%s\n' "${output}" >&2
    return 1
  fi
  identifier="$(tail -n 1 <<<"${output}")"
  [ -n "${identifier}" ] || { echo "GCE instance has no physical id" >&2; return 1; }
  printf 'gce://projects/%s/zones/%s/instances/%s' "${project}" "${zone}" "${identifier}"
}

emit_missing() {
  jq -nc --arg digest "$(absence_digest)" '{tag:"HostTransportMissing",contents:$digest}'
}

emit_prepared() {
  jq -nc --arg physical "$1" --arg old "$2" --arg new "$3" '{tag:"HostTransportPrepared",contents:[$physical,$old,$new]}'
}

emit_state() {
  local tag="$1" physical="$2" closure="$3" acknowledgement="${4:-}"
  if [ -n "${acknowledgement}" ]; then
    jq -nc --arg tag "${tag}" --arg physical "${physical}" --arg closure "${closure}" --arg acknowledgement "${acknowledgement}" '{tag:$tag,contents:[$physical,$closure,$acknowledgement]}'
  else
    jq -nc --arg tag "${tag}" --arg physical "${physical}" --arg closure "${closure}" '{tag:$tag,contents:[$physical,$closure]}'
  fi
}

observe() {
  local physical rc=0
  physical="$(physical_identity)" || rc=$?
  if [ "${rc}" -eq 3 ]; then emit_missing; return; fi
  [ "${rc}" -eq 0 ] || return "${rc}"
  emit_prepared "${physical}" "unobserved" "unobserved"
}

prepare() {
  local physical rc=0 old new config_ref
  physical="$(physical_identity)" || rc=$?
  if [ "${rc}" -eq 3 ]; then emit_missing; return; fi
  [ "${rc}" -eq 0 ] || return "${rc}"
  config_ref="${NAGARE_HOST_FLAKE}#nixosConfigurations.${attribute}.config.system.build.toplevel"
  new="$(nix build --no-link --print-out-paths "${config_ref}" | tail -n 1)"
  old="$(ssh -o BatchMode=yes "${destination}" 'readlink -f /run/current-system' | tail -n 1)"
  [ -n "${new}" ] && [ -n "${old}" ] || { echo "host preparation returned an empty closure" >&2; return 1; }
  emit_prepared "${physical}" "${old}" "${new}"
}

inspect() {
  local physical rc=0 old new status current profile timer proof_line proof
  physical="$(physical_identity)" || rc=$?
  if [ "${rc}" -eq 3 ]; then emit_missing; return; fi
  [ "${rc}" -eq 0 ] || return "${rc}"
  old="$(jq -er '.plan.expectedOldClosure' <<<"${request}")"
  new="$(jq -er '.plan.newClosure' <<<"${request}")"
  status="$(ssh -o BatchMode=yes "${destination}" \
    'printf "current=%s\n" "$(readlink -f /run/current-system)"; printf "profile=%s\n" "$(readlink -f /nix/var/nix/profiles/system 2>/dev/null || true)"; printf "timer=%s\n" "$(systemctl is-active nagare-switch-rollback.timer 2>/dev/null || true)"')"
  current="$(sed -n 's/^current=//p' <<<"${status}" | tail -n 1)"
  profile="$(sed -n 's/^profile=//p' <<<"${status}" | tail -n 1)"
  timer="$(sed -n 's/^timer=//p' <<<"${status}" | tail -n 1)"
  if [ "${timer}" = active ]; then
    emit_state HostTransportArmed "${physical}" "${current}"
  elif [ "${current}" = "${new}" ] && [ "${profile}" = "${new}" ]; then
    proof_line="nagare-host-observation\tcommitted\t${physical}\t${new}\tfresh-login"
    proof="sha256:$(printf '%b' "${proof_line}" | shasum -a 256 | awk '{print $1}')"
    emit_state HostTransportCommitted "${physical}" "${current}" "${proof}"
  elif [ "${current}" = "${old}" ]; then
    emit_state HostTransportBefore "${physical}" "${current}"
  else
    emit_state HostTransportReverted "${physical}" "${current}"
  fi
}

activate() {
  local physical new old output receipt closure proof
  physical="$(physical_identity)"
  new="$(jq -er '.plan.newClosure' <<<"${request}")"
  old="$(jq -er '.plan.expectedOldClosure' <<<"${request}")"
  output="$(NAGARE_HOST_ATTR="${attribute}" NAGARE_SSH_HOST="${destination#*@}" \
    NAGARE_HOST_PREPARED_CLOSURE="${new}" NAGARE_HOST_EXPECTED_OLD_CLOSURE="${old}" \
    bash "${script_dir}/host-switch.sh")"
  printf '%s\n' "${output}" >&2
  receipt="$(grep '^nagare-host-activation[[:space:]]' <<<"${output}" | tail -n 1)"
  closure="$(awk -F '\t' '$1 == "nagare-host-activation" && $2 == "committed" && $4 == "fresh-login" { print $3 }' <<<"${receipt}")"
  [ "${closure}" = "${new}" ] || { echo "host activation did not return the reviewed committed closure" >&2; return 1; }
  proof="sha256:$(printf '%s' "${receipt}" | shasum -a 256 | awk '{print $1}')"
  emit_state HostTransportCommitted "${physical}" "${closure}" "${proof}"
}

case "${action}" in
  observe) observe ;;
  prepare) prepare ;;
  inspect) inspect ;;
  activate) activate ;;
esac
