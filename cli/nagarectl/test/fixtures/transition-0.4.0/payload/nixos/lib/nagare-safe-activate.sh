#!/usr/bin/env bash
# On-host half of the self-reverting host switch (ExecPlan 115, ADR 11). Runs as root.
#
#   arm NEW WINDOW   schedule a rollback to the committed generation in WINDOW seconds
#   activate NEW     start activating NEW, without making it the boot default
#   activation NEW   report whether that activation is still running, and its exit code
#   commit NEW       cancel the rollback and make NEW the boot default
#   status           show the running system, the boot default, and the rollback timer
#
# Until `commit`, both the rollback timer and a reboot return the host to the boot-default
# generation, so a configuration that removes the operator's access undoes itself.
set -euo pipefail

export PATH="/run/current-system/sw/bin:/run/wrappers/bin:${PATH:-/usr/bin:/bin}"

UNIT=nagare-switch-rollback
ACTIVATE_UNIT=nagare-switch-activate
PROFILE=/nix/var/nix/profiles/system
# sudo resets the environment, so on a host this is always /run/nagare-switch.
STATE_DIR="${NAGARE_SWITCH_STATE_DIR:-/run/nagare-switch}"

die() {
  echo "nagare-safe-activate: $*" >&2
  exit 1
}

require_toplevel() {
  [ -x "$1/bin/switch-to-configuration" ] || die "not a NixOS toplevel: $1"
}

cmd_arm() {
  local new="$1" window="$2" current prev
  require_toplevel "$new"
  case "$window" in '' | *[!0-9]*) die "window must be a number of seconds: $window" ;; esac
  current="$(readlink -f /run/current-system)"
  # Roll back to the boot default: the last committed generation, which is also what a
  # reboot would run. Fall back to the running system when there is no usable profile.
  prev="$(readlink -f "$PROFILE" 2>/dev/null || true)"
  if [ -z "$prev" ] || [ ! -x "$prev/bin/switch-to-configuration" ]; then
    prev="$current"
  fi
  if [ "$current" = "$new" ] && [ "$prev" = "$new" ]; then
    echo "ALREADY_ACTIVE new=$new"
    return 0
  fi
  systemctl stop "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1 || true
  systemctl reset-failed "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1 || true
  systemd-run --unit="$UNIT" --on-active="${window}s" --timer-property=AccuracySec=1s \
    "$prev/bin/switch-to-configuration" test
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$prev" > "$STATE_DIR/prev"
  printf '%s\n' "$new" > "$STATE_DIR/new"
  echo "ARMED prev=$prev new=$new seconds=$window"
}

activation_running() {
  case "$(systemctl show -p ActiveState --value "$ACTIVATE_UNIT.service" 2>/dev/null || true)" in
    active | activating | deactivating | reloading) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_activate() {
  local new="$1" shell
  require_toplevel "$new"
  if activation_running; then
    echo "ACTIVATION_RUNNING"
    return 0
  fi
  # F95: a configuration that restarts tailscaled, sshd or the network kills the SSH
  # session that runs this. The activation is a detached transient service: it never
  # waits on that session, and its output goes to the journal, never to a pipe into
  # the session (switch-to-configuration exits 101 when that pipe is gone). The client
  # reads the result with `activation` over fresh logins.
  mkdir -p "$STATE_DIR"
  rm -f "$STATE_DIR/activate-rc"
  printf '%s\n' "$new" > "$STATE_DIR/activating"
  systemctl reset-failed "$ACTIVATE_UNIT.service" >/dev/null 2>&1 || true
  shell="$(readlink -f "$(command -v bash)")"
  # The exit code is informational: pre-existing failed units make it non-zero; the
  # fresh-login verification decides success. The unit's PATH has no coreutils, so
  # the wrapper uses only shell builtins; `activation` reads the file only after the
  # unit has exited.
  systemd-run --unit="$ACTIVATE_UNIT" --collect --no-ask-password --quiet --service-type=exec \
    "$shell" -c 'rc=0; "$1/bin/switch-to-configuration" test || rc=$?; printf "%s\n" "$rc" > "$2"' \
    nagare-switch-activate "$new" "$STATE_DIR/activate-rc"
  echo "ACTIVATION_STARTED new=$new"
}

cmd_activation() {
  local new="$1" rc
  if activation_running; then
    echo "ACTIVATION_RUNNING"
    return 0
  fi
  rc="$(cat "$STATE_DIR/activate-rc" 2>/dev/null || true)"
  if [ -z "$rc" ] || [ "$(cat "$STATE_DIR/activating" 2>/dev/null || true)" != "$new" ]; then
    # Killed before it recorded a result, or a reboot cleared /run: nothing to commit.
    echo "ACTIVATION_UNKNOWN"
    return 0
  fi
  echo "ACTIVATION_DONE rc=$rc new=$new"
}

cmd_commit() {
  local new="$1" state current
  require_toplevel "$new"
  # Never make a half-activated configuration the boot default.
  if activation_running; then
    echo "ACTIVATION_RUNNING"
    exit 1
  fi
  systemctl stop "$UNIT.timer" >/dev/null 2>&1 || true
  state="$(systemctl show -p ActiveState --value "$UNIT.service" 2>/dev/null || true)"
  current="$(readlink -f /run/current-system)"
  case "$state" in
    '' | inactive | failed) ;;
    *) echo "ROLLED_BACK_BEFORE_COMMIT rollback=$state"; exit 1 ;;
  esac
  if [ "$current" != "$new" ]; then
    echo "ROLLED_BACK_BEFORE_COMMIT current=$current"
    exit 1
  fi
  nix-env -p "$PROFILE" --set "$new"
  "$new/bin/switch-to-configuration" boot
  systemctl reset-failed "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR"
  echo "COMMITTED new=$new"
}

cmd_status() {
  echo "current=$(readlink -f /run/current-system)"
  echo "profile=$(readlink -f "$PROFILE" 2>/dev/null || echo none)"
  systemctl list-timers --all --no-pager "$UNIT.timer" || true
}

sub="${1:-}"
[ "$#" -gt 0 ] && shift
case "$sub" in
  arm) [ "$#" -eq 2 ] || die "usage: arm NEW SECONDS"; cmd_arm "$@" ;;
  activate) [ "$#" -eq 1 ] || die "usage: activate NEW"; cmd_activate "$@" ;;
  activation) [ "$#" -eq 1 ] || die "usage: activation NEW"; cmd_activation "$@" ;;
  commit) [ "$#" -eq 1 ] || die "usage: commit NEW"; cmd_commit "$@" ;;
  status) cmd_status ;;
  *) die "usage: {arm NEW SECONDS|activate NEW|activation NEW|commit NEW|status}" ;;
esac
