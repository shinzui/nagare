#!/usr/bin/env bash
# On-host half of the self-reverting host switch (ExecPlan 115, ADR 11). Runs as root.
#
#   arm NEW WINDOW   schedule a rollback to the committed generation in WINDOW seconds
#   activate NEW     activate NEW without making it the boot default
#   commit NEW       cancel the rollback and make NEW the boot default
#   status           show the running system, the boot default, and the rollback timer
#
# Until `commit`, both the rollback timer and a reboot return the host to the boot-default
# generation, so a configuration that removes the operator's access undoes itself.
set -euo pipefail

export PATH="/run/current-system/sw/bin:/run/wrappers/bin:${PATH:-/usr/bin:/bin}"

UNIT=nagare-switch-rollback
PROFILE=/nix/var/nix/profiles/system
STATE_DIR=/run/nagare-switch

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

cmd_activate() {
  local new="$1" rc=0
  require_toplevel "$new"
  # Run in a transient service, as nixos-rebuild does, so a dropped SSH session cannot kill
  # the activation halfway. The exit code is informational: pre-existing failed units make
  # it non-zero; the fresh-login verification decides success.
  systemd-run --unit=nagare-switch-activate --collect --no-ask-password --pipe --quiet \
    --service-type=exec --wait "$new/bin/switch-to-configuration" test || rc=$?
  echo "ACTIVATE_RC=$rc"
}

cmd_commit() {
  local new="$1" state current
  require_toplevel "$new"
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
  commit) [ "$#" -eq 1 ] || die "usage: commit NEW"; cmd_commit "$@" ;;
  status) cmd_status ;;
  *) die "usage: {arm NEW SECONDS|activate NEW|commit NEW|status}" ;;
esac
