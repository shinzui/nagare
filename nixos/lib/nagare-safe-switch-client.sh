# shellcheck shell=bash
# Workstation half of the self-reverting host switch (ExecPlan 115, ADR 11). Source it.

# nagare_safe_switch TARGET NEW SECONDS ACTIVATE_SCRIPT
#   TARGET: user@host; NEW: toplevel store path already present on the host;
#   ACTIVATE_SCRIPT: path to nagare-safe-activate.sh on this machine.
# Uses NIX_SSHOPTS (word-split) for every ssh. Returns 0 only after COMMITTED, 4 when
# access could not be verified (the host then reverts by itself).
nagare_safe_switch() {
  local target="$1" new="$2" window="$3" activate_script="$4"
  local script out attempt verified=0 finished=0 polls deadline err
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
  # F95: a keepalive on every connection. An activation that restarts the network
  # can leave a session whose peer is gone; without probes an idle client never
  # learns that and waits forever. OpenSSH keeps the first value for each option.
  local -a keepalive=(-o ServerAliveInterval=5 -o ServerAliveCountMax=3)

  _nagare_ssh() {
    if [ "${#sshopts[@]}" -gt 0 ]; then
      # shellcheck disable=SC2029 # callers deliberately pass a pre-quoted remote command.
      ssh "${keepalive[@]}" "${sshopts[@]}" "$@"
    else
      # shellcheck disable=SC2029 # callers deliberately pass a pre-quoted remote command.
      ssh "${keepalive[@]}" "$@"
    fi
  }

  _nagare_fresh_ssh() {
    # The fresh-connection requirements come before NIX_SSHOPTS, which may name a
    # live control socket that would otherwise win.
    if [ "${#sshopts[@]}" -gt 0 ]; then
      ssh -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=15 "${keepalive[@]}" "${sshopts[@]}" "$@"
    else
      ssh -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=15 "${keepalive[@]}" "$@"
    fi
  }

  _nagare_remote_command() {
    printf '%q ' sudo -n bash -c "$script" nagare-safe-activate "$@"
  }

  _nagare_remote() {
    # shellcheck disable=SC2029 # the remote command is deliberately pre-quoted with %q.
    # BatchMode: after a key removal ssh would otherwise wait forever at a password prompt.
    _nagare_ssh -o BatchMode=yes "$target" "$(_nagare_remote_command "$@")" </dev/null
  }

  echo "host-switch: arming rollback on $target (window ${window}s)"
  deadline=$(( SECONDS + window - 90 ))
  out="$(_nagare_remote arm "$new" "$window")" || { printf '%s\n' "$out"; echo "host-switch: arm failed; nothing was changed" >&2; return 1; }
  printf '%s\n' "$out"
  case "$out" in *ALREADY_ACTIVE*) return 0 ;; esac

  echo "host-switch: activating $new (not yet the boot default)"
  # The host runs the activation detached; this session may die while it runs.
  _nagare_remote activate "$new" || true

  # Wait for the activation's result over fresh logins: access proven before it
  # finished proves nothing about the units it restarts afterwards. Stop polling in
  # time to verify and commit before the rollback fires.
  polls=$(( (window - 90) / 5 ))
  [ "$polls" -ge 6 ] || polls=6
  for attempt in $(seq 1 "$polls"); do
    [ "$attempt" -eq 1 ] || [ "$SECONDS" -lt "$deadline" ] || break
    # shellcheck disable=SC2029 # the remote command is deliberately pre-quoted with %q.
    out="$(_nagare_fresh_ssh "$target" "$(_nagare_remote_command activation "$new")" </dev/null 2>"$err")" || true
    case "$out" in
      *ACTIVATION_DONE*)
        finished=1
        echo "host-switch: activation finished: $(printf '%s\n' "$out" | tail -n 1)"
        break
        ;;
      *ACTIVATION_RUNNING*) ;;
      *ACTIVATION_UNKNOWN*)
        echo "host-switch: the activation stopped without a result" >&2
        break
        ;;
      *) echo "host-switch: activation status unavailable (attempt $attempt); ssh: $(tr '\n' ' ' < "$err")" >&2 ;;
    esac
    sleep 5
  done

  for attempt in 1 2 3 4 5 6; do
    [ "$finished" -eq 1 ] || break
    # A brand-new connection: an existing session survives a key removal and would
    # "verify" a host nobody can log in to.
    # Compare stdout only: ssh warnings (e.g. "Permanently added … to known hosts") go to
    # stderr and must not turn a working login into a failed verification.
    out="$(_nagare_fresh_ssh \
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
    case "$out" in
      *COMMITTED\ new=*)
        printf 'nagare-host-activation\tcommitted\t%s\tfresh-login\n' "$new"
        return 0
        ;;
    esac
  fi

  echo "NOT COMMITTED: the activation did not finish or access could not be verified. The host reverts to the previous configuration within ${window} s of arming (and on any reboot). Do not run further commands against it; wait, then check with a fresh ssh."
  return 4
}
