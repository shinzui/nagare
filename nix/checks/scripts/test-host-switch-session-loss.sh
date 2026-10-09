#!/usr/bin/env bash
# F95: a host configuration that restarts tailscaled, sshd or the network kills the
# SSH session that started its activation. The activation must finish anyway, its
# output must not depend on that session, and the client must learn the result over
# fresh logins before it verifies access and commits.
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
activate_script="${repo_root}/nixos/lib/nagare-safe-activate.sh"
fixture="$(mktemp -d)"
cleanup() {
  local status="$?"
  if [ "$status" -ne 0 ]; then
    for evidence in journal session.out calls.log; do
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

fail() { echo "FAIL: $*" >&2; exit 1; }

write_executable() {
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
  chmod +x "$path"
}

mkdir -p "$fixture/bin" "$fixture/new/bin" "$fixture/state"
export NAGARE_SWITCH_STATE_DIR="$fixture/state"
export NAGARE_TEST_FIXTURE="$fixture"
printf '%s\n' /nix/store/old-system > "$fixture/current"

# The new system's activation: it starts, then (like a tailscaled or network
# restart) kills the session that is reading its output, then keeps working and
# writing output. Writing into a dead session fails, as the Rust
# switch-to-configuration panics with exit 101 when its piped stdout is gone.
write_executable "$fixture/new/bin/switch-to-configuration" \
  "#!$BASH" \
  'trap "" PIPE' \
  'PATH="${NAGARE_TEST_PATH:?}"' \
  'fixture="${NAGARE_TEST_FIXTURE:?}"' \
  'case "${1:-}" in' \
  '  boot) touch "$fixture/booted"; exit 0 ;;' \
  '  test) ;;' \
  '  *) exit 64 ;;' \
  'esac' \
  'printf "%s\n" "activating the configuration..." || exit 101' \
  'printf "%s\n" "$(cd "$fixture" && pwd)/new" > "$fixture/current"' \
  'if [ -f "$fixture/session.pid" ]; then kill -KILL "$(cat "$fixture/session.pid")" 2>/dev/null || true; fi' \
  'while [ -f "$fixture/hold" ]; do sleep 0.05; done' \
  'sleep 0.2' \
  'printf "%s\n" "restarting the following units: tailscaled.service" || exit 101' \
  'touch "$fixture/activated"'

# systemd-run: --pipe attaches the unit to the caller's stdio, --wait waits for it;
# without --pipe the unit's output goes to the journal and it outlives the caller.
# A unit's PATH has no coreutils on NixOS, so the unit runs with an empty PATH.
write_executable "$fixture/bin/systemd-run" \
  "#!$BASH" \
  'set -euo pipefail' \
  'fixture="${NAGARE_TEST_FIXTURE:?}"' \
  'printf "systemd-run %s\n" "$*" >> "$fixture/calls.log"' \
  'pipe=0; wait_unit=0; unit=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in' \
  '    --pipe) pipe=1 ;;' \
  '    --wait) wait_unit=1 ;;' \
  '    --unit=*) unit="${1#--unit=}" ;;' \
  '    --on-active=*) exit 0 ;;' \
  '    --*) ;;' \
  '    *) break ;;' \
  '  esac' \
  '  shift' \
  'done' \
  'state="$fixture/unit-${unit}"' \
  'echo active > "$state"' \
  'run_unit() { local rc=0; PATH=/var/empty "$@" || rc=$?; echo inactive > "$state"; return "$rc"; }' \
  'if [ "$pipe" -eq 1 ]; then' \
  '  run_unit "$@"' \
  'elif [ "$wait_unit" -eq 1 ]; then' \
  '  run_unit "$@" >> "$fixture/journal" 2>&1 </dev/null' \
  'else' \
  '  ( trap "" HUP; run_unit "$@" >> "$fixture/journal" 2>&1 </dev/null ) &' \
  'fi'

write_executable "$fixture/bin/systemctl" \
  "#!$BASH" \
  'fixture="${NAGARE_TEST_FIXTURE:?}"' \
  'printf "systemctl %s\n" "$*" >> "$fixture/calls.log"' \
  'unit="${*: -1}"; unit="${unit%.service}"; unit="${unit%.timer}"' \
  'state="$(cat "$fixture/unit-${unit}" 2>/dev/null || echo inactive)"' \
  'case "$1" in' \
  '  is-active) [ "${2:-}" = --quiet ] || echo "$state"; [ "$state" = active ] ;;' \
  '  show) echo "$state" ;;' \
  '  *) exit 0 ;;' \
  'esac'

write_executable "$fixture/bin/readlink" \
  "#!$BASH" \
  'fixture="${NAGARE_TEST_FIXTURE:?}"' \
  'if [ "${*: -1}" = /run/current-system ]; then cat "$fixture/current"; exit 0; fi' \
  'if [ "${*: -1}" = /nix/var/nix/profiles/system ]; then echo /nix/store/old-system; exit 0; fi' \
  "exec $(command -v readlink) \"\$@\""

write_executable "$fixture/bin/nix-env" \
  "#!$BASH" \
  'printf "nix-env %s\n" "$*" >> "${NAGARE_TEST_FIXTURE:?}/calls.log"'

export NAGARE_TEST_PATH="$PATH"
export PATH="$fixture/bin:$PATH"
new="$(cd "$fixture" && pwd)/new"

wait_for_activation() {
  local out attempt
  for attempt in $(seq 1 200); do
    out="$(bash "$activate_script" activation "$new")"
    case "$out" in
      *ACTIVATION_DONE*) printf '%s\n' "$out"; return 0 ;;
      *ACTIVATION_RUNNING*) sleep 0.05 ;;
      *) fail "unexpected activation status: $out" ;;
    esac
  done
  fail "activation never finished"
}

# 1. The session that starts the activation dies mid-switch; the switch completes.
mkfifo "$fixture/session.pipe"
cat "$fixture/session.pipe" > "$fixture/session.out" &
echo "$!" > "$fixture/session.pid"
bash "$activate_script" activate "$new" > "$fixture/session.pipe" 2>&1 || true
status="$(wait_for_activation)"
[ -f "$fixture/activated" ] || fail "the activation stopped when its session died: $status"
case "$status" in *"ACTIVATION_DONE rc=0 "*) ;; *) fail "activation result was not recorded: $status" ;; esac
grep -q 'restarting the following units' "$fixture/journal" || fail "activation output did not reach the journal"
rm -f "$fixture/session.pid" "$fixture/activated"
echo "ok: an activation outlives the session that started it"

# 2. Commit refuses while the activation still runs, then commits once it finished.
printf '%s\n' /nix/store/old-system > "$fixture/current"
rm -f "$fixture/state/activate-rc"
touch "$fixture/hold"
bash "$activate_script" activate "$new" > /dev/null
for _ in $(seq 1 100); do [ "$(cat "$fixture/current")" = "$new" ] && break; sleep 0.05; done
rc=0
out="$(bash "$activate_script" commit "$new")" || rc=$?
[ "$rc" -ne 0 ] || fail "commit succeeded while the activation was still running: $out"
case "$out" in *ACTIVATION_RUNNING*) ;; *) fail "commit did not report the running activation: $out" ;; esac
! grep -q '^nix-env' "$fixture/calls.log" || fail "commit changed the boot default during the activation"
[ ! -f "$fixture/booted" ] || fail "commit installed the boot entry during the activation"
rm -f "$fixture/hold"
wait_for_activation > /dev/null
out="$(bash "$activate_script" commit "$new")" || fail "commit after a finished activation failed: $out"
case "$out" in *"COMMITTED new=$new"*) ;; *) fail "commit output: $out" ;; esac
[ -f "$fixture/booted" ] || fail "commit did not install the boot entry"
echo "ok: commit waits for the activation to finish"

# 3. The client: the activating session is lost and the host is unreachable for a
# while. The client learns the result over fresh logins, and only then verifies and
# commits. Every ssh has a keepalive, so a session on a dead network cannot hang.
client_run() {
  local scenario="$1"
  : > "$fixture/client.log"
  echo 0 > "$fixture/polls"
  (
    set -euo pipefail
    # shellcheck source=../../../nixos/lib/nagare-safe-switch-client.sh
    source "${repo_root}/nixos/lib/nagare-safe-switch-client.sh"
    sleep() { :; }
    # A live control socket in NIX_SSHOPTS must never carry a fresh login.
    export NIX_SSHOPTS="-o ControlMaster=auto -o ControlPath=$fixture/live-session"
    ssh() {
      local remote="${*: -1}" polls control
      printf 'ssh %s\n' "$*" >> "$fixture/client.log"
      case " $* " in *" -o ServerAliveInterval="*) ;; *) echo "ssh without keepalive: $*" >> "$fixture/client.log"; return 70 ;; esac
      control="$(printf '%s\n' "$@" | sed -n 's/^ControlPath=//p' | head -n 1)"
      case "$remote" in
        *"nagare-safe-activate activation "* | *"sudo -n true && readlink -f /run/current-system")
          [ "$control" = none ] || { echo "event: login-through-live-session" >> "$fixture/client.log"; return 71; } ;;
      esac
      case "$remote" in
        *"nagare-safe-activate arm "*) echo "ARMED prev=/nix/store/old-system new=$new seconds=600" ;;
        *"nagare-safe-activate activate "*) echo "event: activate-session-lost" >> "$fixture/client.log"; return 255 ;;
        *"nagare-safe-activate activation "*)
          polls="$(( $(cat "$fixture/polls") + 1 ))"; echo "$polls" > "$fixture/polls"
          case "$scenario:$polls" in
            lost:1 | lost:2) return 255 ;;
            lost:3) echo ACTIVATION_RUNNING ;;
            lost:*) echo "event: activation-done" >> "$fixture/client.log"; echo "ACTIVATION_DONE rc=0 new=$new" ;;
            running:*) echo ACTIVATION_RUNNING ;;
            unknown:*) echo ACTIVATION_UNKNOWN ;;
          esac
          ;;
        *"sudo -n true && readlink -f /run/current-system")
          echo "event: verify" >> "$fixture/client.log"
          echo "$new"
          ;;
        *"nagare-safe-activate commit "*) echo "event: commit" >> "$fixture/client.log"; echo "COMMITTED new=$new" ;;
        *) return 64 ;;
      esac
    }
    nagare_safe_switch deploy@host "$new" 600 "$activate_script"
  ) > "$fixture/client.out" 2>&1
}

rc=0; client_run lost || rc=$?
[ "$rc" -eq 0 ] || fail "client did not commit after a lost session (rc=$rc): $(cat "$fixture/client.out")"
! grep -q 'without keepalive' "$fixture/client.log" || fail "an ssh call has no keepalive: $(grep 'without keepalive' "$fixture/client.log")"
events="$(sed -n 's/^event: //p' "$fixture/client.log" | tr '\n' ' ')"
[ "$events" = "activate-session-lost activation-done verify commit " ] \
  || fail "client order was '$events'; access must be verified only after the activation finished"
echo "ok: the client waits through a lost session, then verifies and commits"

for scenario in running unknown; do
  rc=0; client_run "$scenario" || rc=$?
  [ "$rc" -eq 4 ] || fail "client returned $rc for an activation that is $scenario"
  ! grep -q 'event: verify\|event: commit' "$fixture/client.log" \
    || fail "client verified or committed an activation that is $scenario"
done
echo "ok: an unfinished or unknown activation is never committed"

echo "PASS: host activation survives the loss of its session"
