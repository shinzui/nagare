#!/usr/bin/env bash
# Stop hook (operator, 2026-11-14): a session that owns a plan does not end its
# turn while the plan's Progress list has unchecked items. A session takes
# ownership by writing the plan's absolute path to
# ${XDG_STATE_HOME:-$HOME/.local/state}/nagare/plan-owners/<session id>.
# The first stop is blocked with a reminder; the second (stop_hook_active)
# passes, so a session waiting on a background task, a refusing guard or an
# operator question is never trapped.
set -euo pipefail
input=$(cat)
session=$(jq -r '.session_id // empty' <<<"$input")
active=$(jq -r '.stop_hook_active // false' <<<"$input")
[ -n "$session" ] && [ "$active" != "true" ] || exit 0
owner="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/plan-owners/$session"
[ -f "$owner" ] || exit 0
plan=$(head -n 1 "$owner")
[ -f "$plan" ] || exit 0
open=$(awk '/^## Progress/{p=1;next} /^## /{p=0} p && /^- \[ \]/' "$plan" | cut -c1-100)
[ -n "$open" ] || exit 0
jq -n --arg plan "$plan" --arg open "$open" '{decision: "block", reason: ("You own " + $plan + " and its Progress list still has unchecked items:\n" + $open + "\nKeep working on them. Stop only if you are waiting on a background task that will wake you, a guard refused, or the operator must answer a question; then say which in your reply and stop again.")}'
