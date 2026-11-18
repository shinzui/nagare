# shellcheck shell=bash
# Drills on one warm disposable local context (operator, 2026-11-17). A drill is
# resumable at a step and idempotent on its root, so a drill bug never costs a
# rebuild of the context:
#   NAGARE_DRILL_FROM=N    runs from step N on the same root;
#   drill_kept NAME CMD    a value later steps or a rerun need (an ID, a key), on disk;
#   drill_reviewed DIR CMD a reviewed change planned and applied once on this root;
#   logs and records are appended, never truncated, after the first step.
# A run's kept values, once-markers and reviews live under DRILL_RUN_DIR until the
# drill passes (drill_passed); the next invocation then starts a new run on the
# same warm context. The sourcing drill defines N (its nagarectl) and fail.
# A drill whose steps are not plain numbers names them in order in DRILL_STEPS
# before it sources this file ("1 2 5a 5b 6"); NAGARE_DRILL_FROM names one of them.
DRILL_STEPS="${DRILL_STEPS:-}"
DRILL_FROM="${NAGARE_DRILL_FROM:-${DRILL_STEPS%% *}}"
DRILL_FROM="${DRILL_FROM:-1}"
drill_step_index() { # step; its position in DRILL_STEPS, or the step itself when none
  local i=0 step
  [ -n "${DRILL_STEPS:-}" ] || { printf '%s\n' "$1"; return; }
  for step in $DRILL_STEPS; do i=$((i + 1)); [ "$step" != "$1" ] || { printf '%s\n' "$i"; return; }; done
  echo "drill: no step $1 in: $DRILL_STEPS" >&2; exit 1
}
DRILL_FROM_INDEX="$(drill_step_index "$DRILL_FROM")"
step_on() { [ "$DRILL_FROM_INDEX" -le "$(drill_step_index "$1")" ]; }

drill_init() { # the drill's state directory under its root
  DRILL_DIR="$1"
  mkdir -p "$DRILL_DIR"
  chmod 700 "$DRILL_DIR"
  [ -s "$DRILL_DIR/run" ] || printf 's%s\n' "$(date -u +%m%d%H%M%S)" > "$DRILL_DIR/run"
  DRILL_RUN="$(cat "$DRILL_DIR/run")"
  DRILL_RUN_DIR="$DRILL_DIR/runs/$DRILL_RUN"
  mkdir -p "$DRILL_RUN_DIR/reviews"
  printf '%s drill: run %s, from step %s, state %s\n' "$(date -u +%H:%M:%S)" "$DRILL_RUN" "$DRILL_FROM" "$DRILL_RUN_DIR"
}

# The run passed: the next invocation starts a new one.
drill_passed() { mv "$DRILL_DIR/run" "$DRILL_RUN_DIR/passed"; }

# The value saved under NAME, or CMD's output, saved there first. Kept values are
# private to the root; a record never names one.
drill_kept() { # name command...
  local file="$DRILL_RUN_DIR/kept-$1"; shift
  if [ ! -s "$file" ]; then
    (umask 077; "$@" > "$file.new") || { rm -f "$file.new"; return 1; }
    [ -s "$file.new" ] || { rm -f "$file.new"; fail "drill_kept: $* printed nothing"; }
    mv "$file.new" "$file"
  fi
  cat "$file"
}

# Run CMD once on this root: a change that is not a saved review (a site deploy,
# a server create) and that a rerun must not repeat. Its output is appended to
# DRILL_RUN_DIR/once-NAME.log.
drill_once() { # name command...
  local name="$1"; shift
  [ ! -f "$DRILL_RUN_DIR/once-$name" ] || return 0
  "$@" >> "$DRILL_RUN_DIR/once-$name.log" 2>&1 || fail "$name: $(tail -3 "$DRILL_RUN_DIR/once-$name.log")"
  : > "$DRILL_RUN_DIR/once-$name"
}

# An ambiguous transaction an earlier apply of this review left, resumed.
drill_resume_ambiguous() { # apply log
  local tx n
  tx="$(sed -n "s/^ambiguous \(tx-[0-9a-f]*\) at .*/\1/p" "$1" 2>/dev/null | tail -1)"
  [ -n "$tx" ] || return 1
  for n in $(seq 1 12); do
    printf '%s drill: resume %s of %s\n' "$(date -u +%H:%M:%S)" "$n" "$tx" >> "$1"
    if N inventory resume "$tx" --yes >> "$1" 2>&1; then return 0; fi
    tail -2 "$1" | grep -q "^ambiguous $tx at " || return 1
    sleep 20
  done
  return 1
}

# Plan a reviewed change into DIR and apply it, once on this root. A review that
# was applied is not planned again; one whose apply left an ambiguous transaction
# resumes it; one that was planned and never applied is set aside, because a
# saved review is never overwritten, and planned again. The plan's output is in
# DIR.out, its log in DIR.plan.log, the apply's in DIR.apply.log.
drill_reviewed() { # dir plan-command (without --save-plan)...
  local dir="$1"; shift
  drill_saved "$@" --save-plan "$dir" > /dev/null 2>> "$dir.plan.log" || fail "plan $dir: $(tail -3 "$dir.plan.log")"
  drill_apply "$dir"
}

# Run a command that may save a review (--save-plan DIR), once per review on this
# run: for a review already applied, its saved output is printed again and the
# command does not run; an ambiguous apply is resumed first; an unapplied review
# is set aside and planned again. Commands without --save-plan just run.
drill_saved() { # command...
  local dir="" previous="" arg rc=0
  for arg in "$@"; do [ "$previous" != --save-plan ] || dir="$arg"; previous="$arg"; done
  [ -n "$dir" ] || { "$@"; return; }
  if [ ! -f "$dir.applied" ] && [ -e "$dir" ] && drill_resume_ambiguous "$dir.apply.log"; then : > "$dir.applied"; fi
  if [ -f "$dir.applied" ]; then cat "$dir.out" 2>/dev/null || true; return 0; fi
  [ ! -e "$dir" ] || mv "$dir" "$dir.unapplied-$(date -u +%Y%m%dT%H%M%S)"
  "$@" > "$dir.out" || rc=$?
  cat "$dir.out"
  return "$rc"
}

# Apply a review saved by other means (a plan command that writes DIR itself),
# once on this root.
drill_apply() { # dir
  [ ! -f "$1.applied" ] || return 0
  N inventory apply "$1" --yes >> "$1.apply.log" 2>&1 || drill_resume_ambiguous "$1.apply.log" \
    || fail "apply of $1: $(tail -3 "$1.apply.log")"
  : > "$1.applied"
}

# The Docker daemon's VM shares DIR with the workstation, so a hostPath under it
# is the workstation's directory on the node, not an empty one. Probed through
# the daemon itself: a Colima profile shares only the directories it mounts.
drill_require_daemon_mount() { # dir
  local dir="$1" value="probe-$$-$RANDOM" image cid seen
  printf '%s\n' "$value" > "$dir/.daemon-mount-probe"
  image="$(docker image ls -q | head -1)"
  [ -n "$image" ] || fail "the Docker daemon has no image to probe its shared directories with"
  cid="$(docker create -v "$dir:/probe:ro" "$image" /probe)"
  seen="$(docker cp "$cid:/probe/.daemon-mount-probe" - 2>/dev/null | tar -xO 2>/dev/null || true)"
  docker rm "$cid" > /dev/null
  rm -f "$dir/.daemon-mount-probe"
  [ "$seen" = "$value" ] || fail "the Docker daemon's VM does not share $dir, so its hostPath mounts would be empty on the node; put the drill root under a directory the daemon mounts (nagare-c4-amd64 shares ~/.local/state/nagare/releases/x86-work)"
}
