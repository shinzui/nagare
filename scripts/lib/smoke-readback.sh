#!/usr/bin/env bash
# Shared restored-sentinel readback for the smoke scripts.
#
# A pinned reviewed volume restore Job prints, after extraction, one
# `NAGARE_VOLUME_RESTORE_FILE <sha256> <size> <relative-path>` line per restored
# regular file and one `NAGARE_VOLUME_RESTORE_MANIFEST files=… bytes=… tree=…`
# summary line (Nagare.Storage.Restore.volumeManifestPython). Reading the Job log
# is read-only; mounting the scratch PVC from an ad-hoc pod would be an
# unreviewed write.

smoke_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d ' ' -f 1
  else
    shasum -a 256 | cut -d ' ' -f 1
  fi
}

# verify_restored_sentinel NAMESPACE JOB SENTINEL_NAME EXPECTED_CONTENT
verify_restored_sentinel() {
  local namespace="$1" job="$2" name="$3" content="$4" logs expected size line
  logs="$(kubectl -n "${namespace}" logs "job/${job}" -c restore)"
  expected="$(printf '%s' "${content}" | smoke_sha256)"
  size="$(printf '%s' "${content}" | wc -c | tr -d ' ')"
  printf '%s\n' "${logs}" | grep -Eq '^NAGARE_VOLUME_RESTORE_MANIFEST files=[0-9]+ bytes=[0-9]+ tree=[0-9a-f]{64}$' || {
    echo "smoke: restore Job ${job} printed no restore manifest" >&2
    return 1
  }
  line="$(printf '%s\n' "${logs}" | awk -v name="${name}" \
    '$1 == "NAGARE_VOLUME_RESTORE_FILE" && ($4 == name || substr($4, length($4) - length(name)) == "/" name)')"
  [ -n "${line}" ] || { echo "smoke: restored manifest lacks ${name}" >&2; return 1; }
  [ "$(printf '%s\n' "${line}" | wc -l | tr -d ' ')" = 1 ] || { echo "smoke: restored manifest repeats ${name}" >&2; return 1; }
  set -- ${line}
  [ "$2" = "${expected}" ] && [ "$3" = "${size}" ] || {
    echo "smoke: restored ${name} has sha256 $2 and size $3, expected ${expected} and ${size}" >&2
    return 1
  }
  echo "  restored sentinel verified from the reviewed restore manifest: sha256 ${expected}"
}
