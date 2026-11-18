#!/usr/bin/env bash
# Stop hook (operator, 2026-11-14): a session that owns a plan does not end its
# turn while the plan's Progress list has unchecked items. A session takes
# ownership by writing the plan's absolute path to
# ${XDG_STATE_HOME:-$HOME/.local/state}/nagare/plan-owners/<session id>.
# The first stop is blocked with a reminder; the second (stop_hook_active)
# passes, so a session waiting on a guard or an operator question is never
# trapped. A session with a background task still pending is waiting on its
# notification, so the hook stays silent (operator, 2026-11-17).
set -euo pipefail
input=$(cat)
session=$(jq -r '.session_id // empty' <<<"$input")
active=$(jq -r '.stop_hook_active // false' <<<"$input")
transcript=$(jq -r '.transcript_path // empty' <<<"$input")
[ -n "$session" ] && [ "$active" != "true" ] || exit 0
owner="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/plan-owners/$session"
[ -f "$owner" ] || exit 0
plan=$(head -n 1 "$owner")
[ -f "$plan" ] || exit 0
open=$(awk '/^## Progress/{p=1;next} /^## /{p=0} p && /^- \[ \]/' "$plan" | cut -c1-100)
[ -n "$open" ] || exit 0
# A background command or agent is pending when its launch result has no
# task notification or TaskStop yet. Only launch results, notifications and
# TaskStop calls count, never text that quotes them.
if [ -f "$transcript" ]; then
  pending=$(python3 -I - "$transcript" <<'PY'
import json, re, sys
launched, notified = set(), set()
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if "running in background with ID" not in line and "Async agent launched" not in line \
            and "backgroundTaskId" not in line and "<task-notification>" not in line and '"TaskStop"' not in line:
        continue
    try:
        record = json.loads(line)
    except ValueError:
        continue
    result = record.get("toolUseResult")
    if isinstance(result, dict) and result.get("backgroundTaskId"):
        launched.add(result["backgroundTaskId"])
    texts = []
    if record.get("type") == "queue-operation":
        texts.append(record.get("content") or "")
    content = (record.get("message") or {}).get("content")
    if isinstance(content, str):
        texts.append(content)
    elif isinstance(content, list):
        for part in content:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "tool_use" and part.get("name") == "TaskStop":
                notified.add(str((part.get("input") or {}).get("task_id", "")))
                continue
            inner = part.get("content", part.get("text", ""))
            if isinstance(inner, list):
                inner = "".join(p.get("text", "") for p in inner if isinstance(p, dict))
            texts.append(inner if isinstance(inner, str) else "")
    for text in texts:
        if text.startswith("Command running in background with ID: "):
            launched.update(re.findall(r"^Command running in background with ID: ([A-Za-z0-9]+)", text))
        elif text.startswith("Async agent launched"):
            launched.update(re.findall(r"agentId: ([A-Za-z0-9]+)", text)[:1])
        elif text.lstrip().startswith("<task-notification>"):
            notified.update(re.findall(r"<task-id>([A-Za-z0-9]+)</task-id>", text))
print(len(launched - notified))
PY
  ) || pending=0
  [ "${pending:-0}" = 0 ] || exit 0
fi
jq -n --arg plan "$plan" --arg open "$open" '{decision: "block", reason: ("You own " + $plan + " and its Progress list still has unchecked items:\n" + $open + "\nKeep working on them. Stop only if a guard refused or the operator must answer a question; then say which in your reply and stop again.")}'
