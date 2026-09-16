# shellcheck shell=bash
# Workstation half of the self-reverting host switch (ExecPlan 115, ADR 11). Source it.

# nagare_safe_switch TARGET NEW SECONDS ACTIVATE_SCRIPT
#   TARGET: user@host; NEW: toplevel store path already present on the host;
#   ACTIVATE_SCRIPT: path to nagare-safe-activate.sh on this machine.
# Uses NIX_SSHOPTS (word-split) for every ssh. Returns 0 only after COMMITTED, 4 when
# access could not be verified (the host then reverts by itself).
nagare_safe_switch() {
  local target="$1" new="$2" window="$3" activate_script="$4"
  local script out attempt verified=0 err
  err="$(mktemp)"
  # shellcheck disable=SC2064 # expand $err now; the local is gone when RETURN fires.
  trap "rm -f '$err'" RETURN
  local -a sshopts
  # shellcheck disable=SC2206 # NIX_SSHOPTS is a word-split option string by convention.
  sshopts=(${NIX_SSHOPTS:-})
  script="$(cat "$activate_script")" || return 1

  # macOS still ships Bash 3.2. With nounset enabled it treats expansion of an
  # empty array as an unbound-variable error, unlike current Bash. Branch before
  # expansion so a host reachable through ordinary SSH config needs no dummy
  # NIX_SSHOPTS value.
  _nagare_ssh() {
    if [ "${#sshopts[@]}" -gt 0 ]; then
      # shellcheck disable=SC2029 # callers deliberately pass a pre-quoted remote command.
      ssh "${sshopts[@]}" "$@"
    else
      # shellcheck disable=SC2029 # callers deliberately pass a pre-quoted remote command.
      ssh "$@"
    fi
  }

  _nagare_remote() {
    local remote
    remote="$(printf '%q ' sudo -n bash -c "$script" nagare-safe-activate "$@")"
    # shellcheck disable=SC2029 # $remote is deliberately expanded here, pre-quoted with %q.
    # BatchMode: after a key removal ssh would otherwise wait forever at a password prompt.
    _nagare_ssh -o BatchMode=yes "$target" "$remote" </dev/null
  }

  echo "host-switch: arming rollback on $target (window ${window}s)"
  out="$(_nagare_remote arm "$new" "$window")" || { printf '%s\n' "$out"; echo "host-switch: arm failed; nothing was changed" >&2; return 1; }
  printf '%s\n' "$out"
  case "$out" in *ALREADY_ACTIVE*) return 0 ;; esac

  echo "host-switch: activating $new (not yet the boot default)"
  _nagare_remote activate "$new" || true

  for attempt in 1 2 3 4 5 6; do
    # A brand-new connection: an existing session survives a key removal and would
    # "verify" a host nobody can log in to.
    # Compare stdout only: ssh warnings (e.g. "Permanently added … to known hosts") go to
    # stderr and must not turn a working login into a failed verification.
    out="$(_nagare_ssh -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=15 \
      "$target" 'sudo -n true && readlink -f /run/current-system' </dev/null 2>"$err")" || true
    out="$(printf '%s\n' "$out" | tail -n 1)"
    if [ "$out" = "$new" ]; then
      verified=1
      echo "host-switch: fresh login and sudo verified (attempt $attempt)"
      break
    fi
    echo "host-switch: verification attempt $attempt failed: got '${out}'; ssh: $(tr '\n' ' ' < "$err")" >&2
    [ "$attempt" -lt 6 ] && sleep 10
  done

  if [ "$verified" -eq 1 ]; then
    out="$(_nagare_remote commit "$new" 2>&1)" || true
    printf '%s\n' "$out"
    case "$out" in *COMMITTED\ new=*) return 0 ;; esac
  fi

  echo "NOT COMMITTED: access could not be verified. The host reverts to the previous configuration within ${window} s of arming (and on any reboot). Do not run further commands against it; wait, then check with a fresh ssh."
  return 4
}
