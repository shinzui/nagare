#!/usr/bin/env python3
"""PreToolUse guard for host activation and cloud mutation (ExecPlan 115, ADR 11).

Reads the Claude Code hook JSON on stdin. For Bash commands it denies direct NixOS
activation and startup-script metadata, and asks a human to approve cloud and host
mutations. Any internal error produces a deny decision: a guard that disappears when
it breaks is the failure this hook exists to prevent.
"""

from __future__ import annotations  # keep module import crash-free on older python3

import json
import re
import sys

# A command position: start of string, a shell separator or quote, a newline, a
# command prefix (sudo/exec/doas/env VAR=...), or a path separator so store paths match.
CMD_START = r"(?:^|[;&|(`'\"\n]|\$\(|\bsudo\s+|\bexec\s+|\bdoas\s+|\benv\s+(?:\S+=\S*\s+)*|/)\s*"

DENY = [
    (CMD_START + r"nixos-rebuild(?:-ng)?\b(?=[^;&|\n]*\b(?:switch|boot|test)\b)",
     "Direct NixOS activation is forbidden here. Host changes go only through `just host-switch` (self-reverting, ExecPlan 115). If a guard refused, STOP and report to the user; do not work around it."),
    (CMD_START + r"switch-to-configuration\b",
     "Running switch-to-configuration directly is forbidden. Use `just host-switch`. If it refused, STOP and report. (Use the Grep tool, not a quoted shell grep, to search for this word.)"),
    (r"\bNIXOS_NO_CHECK\s*=",
     "NIXOS_NO_CHECK disables NixOS pre-switch safety checks and is forbidden."),
    (r"\bnix-env\b[^;&|\n]*profiles/system\b",
     "Editing the NixOS system profile directly is forbidden. Use `just host-switch`."),
    (r"\bln\s+-[^;&|\n]*profiles/system\b",
     "Repointing the NixOS system profile is forbidden. Use `just host-switch`."),
    # Only planting a script is denied; removing leftover script metadata is a cleanup that
    # falls through to the instance-mutation ask rule.
    (r"\bgcloud\b(?=[^;&|\n]*\b(?:add-metadata|create)\b)[^;&|\n]*(?:startup-script|shutdown-script)",
     "Startup/shutdown-script metadata is forbidden: it does not run on Nagare's NixOS image and is not an observable recovery tool. STOP and report; recovery uses the documented runbook."),
]

ASK = [
    (r"\bgcloud\b[^;&|\n]*\bcompute\s+instances\s+(?:add-metadata|remove-metadata|stop|start|reset|suspend|resume|delete|create|detach-disk|attach-disk|set-disk-auto-delete|set-machine-type|update)\b",
     "Cloud instance mutation: requires explicit human approval."),
    (r"\bgcloud\b[^;&|\n]*\bcompute\s+(?:disks|snapshots|images)\s+(?:create|delete|resize|snapshot)\b",
     "Cloud disk/snapshot/image mutation: requires explicit human approval."),
    (r"\bpulumi\b[^;&|\n]*\s(?:up|destroy|import|refresh)\b",
     "Pulumi mutation: requires explicit human approval."),
    (r"\bpulumi\b[^;&|\n]*\bstate\s+(?:delete|edit|unprotect|move|rename|repair|upgrade)\b",
     "Pulumi state surgery: requires explicit human approval."),
    (r"\bpulumi\b[^;&|\n]*\bstack\s+(?:rm|import|change-secrets-provider)\b",
     "Pulumi stack mutation: requires explicit human approval."),
    (r"\bjust\s+host-switch\b",
     "Host switch: requires explicit human approval."),
    (r"scripts/host-switch\.sh\b(?![^;&|\n]*--dry-run)",
     "Host switch: requires explicit human approval."),
]

_RULES = [("deny", re.compile(p), r) for p, r in DENY] + [("ask", re.compile(p), r) for p, r in ASK]


def decide(command: str) -> tuple[str, str] | None:
    """Return ("deny"|"ask", reason) for the first matching rule, or None."""
    for decision, pattern, reason in _RULES:
        if pattern.search(command):
            return decision, reason
    return None


def _emit(decision: str, reason: str) -> None:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }}))


def main() -> None:
    try:
        payload = json.load(sys.stdin)
        if payload.get("tool_name") != "Bash":
            return
        command = payload["tool_input"]["command"]
        if not isinstance(command, str):
            raise TypeError("tool_input.command is not a string")
        result = decide(command)
        if result is not None:
            _emit(*result)
    except Exception as exc:  # fail closed
        _emit("deny", f"guard_host_mutation hook failed ({type(exc).__name__}: {exc}); refusing the command (fail closed).")


if __name__ == "__main__":
    main()
