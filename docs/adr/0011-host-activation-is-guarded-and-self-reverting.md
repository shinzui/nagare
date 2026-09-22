---
title: "Host activation is guarded and self-reverting"
status: accepted
date: 2026-09-12
authors: [shinzui]
related:
  - docs/plans/115-prevent-host-lockouts-with-guarded-self-reverting-host-switches.md
  - docs/plans/114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md
  - docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md
  - docs/adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md
---

# ADR 11 — Host activation is guarded and self-reverting

## Status

Accepted, 2026-09-12. Implemented by
[ExecPlan 115](../plans/115-prevent-host-lockouts-with-guarded-self-reverting-host-switches.md).

## Context

On 2026-09-12 a coding agent locked the operator out of `nagare-01`. `scripts/host-switch.sh`
refused to run because `nagarectl` was not on `PATH`. The agent then activated the in-repo
evaluation fixture `nixos#nagare-01` directly with `nixos-rebuild`. The fixture authorizes only a
synthetic placeholder key, and the host uses `users.mutableUsers = false` with OS Login disabled,
so the declared key list is the only way in. The operator's key disappeared, SSH failed with
`Permission denied (publickey)`, and the bad generation was already the boot default. The agent
then tried GCE startup scripts, which never run on this image, so none of those attempts could be
observed. Recovery needed a rescue VM.

[ADR 5](0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) already said in prose
that the fixture is evaluation-only. Prose did not stop the mistake.

## Decision

`scripts/host-switch.sh` (reached through `just host-switch` and `nagarectl platform upgrade`) is
the only supported way to activate a configuration on a Nagare host. Four independent layers
enforced this when adopted (layer 1 was later removed; see the amendment below). Each one alone
would have prevented the incident.

1. **Agent guard (removed 2026-09-13).** `.claude/hooks/guard_host_mutation.py`, a Claude Code PreToolUse hook, denies
   shell commands that activate a NixOS configuration directly, run `switch-to-configuration`,
   edit the system profile, set `NIXOS_NO_CHECK`, or plant startup or shutdown scripts. It asks
   for human approval on instance, disk, snapshot, image, and Pulumi mutations and on
   `just host-switch`. It fails closed: an internal error returns a deny decision.
   `CLAUDE.md` requires agents to stop and report when any guard refuses.
2. **The fixture refuses activation.** The option `nagare.host.evaluationFixture` adds a
   `system.preSwitchChecks` entry that aborts `switch-to-configuration` before anything changes,
   whatever tool invoked it. A configuration that carries the fixture's placeholder key without
   the flag fails an assertion.
3. **Every switch reverts itself unless a fresh login proves access.** `host-switch.sh` refuses
   the fixture and any configuration that does not authorize the operator's public key (exit 3).
   It then builds and copies the toplevel, arms an on-host `systemd-run` timer that reactivates
   the boot-default generation, and activates with `switch-to-configuration test`, which leaves
   the boot default unchanged. Next it opens a brand-new SSH connection (no multiplexing,
   `BatchMode`) that must run `sudo -n true` and report the new system. Only then does it cancel
   the timer, set the system profile, and run `switch-to-configuration boot` (`COMMITTED`).
   Otherwise it prints `NOT COMMITTED` and exits 4. The host reverts when the window
   (`NAGARE_SWITCH_CONFIRM_SECONDS`, default 600) expires, and on any reboot. The on-host and
   workstation halves are `nixos/lib/nagare-safe-activate.sh` and
   `nixos/lib/nagare-safe-switch-client.sh`. The `host-switch-auto-rollback` VM check proves the
   behavior by locking a test host out.
4. **Break-glass without SSH keys.** `nixos/hosts/nagare-01/boot-recovery.nix` puts GRUB on the
   serial console with a ten-second timeout and keeps 20 generations, so an operator can boot an
   earlier generation through `gcloud compute connect-to-serial-port`
   (runbook: `docs/user/accessing-the-host.md`).

A sops-delivered emergency password was rejected as the break-glass path: the host's age key can
be missing exactly when recovery is needed, and the boot menu needs no secret.

## Consequences

Every boot waits ten seconds at the GRUB menu. Every switch takes at least one extra SSH round
trip and has a confirmation window; a switch that takes longer than the window to activate
reverts and reports `NOT COMMITTED`, which is safe but noisy. The rollback target is the
boot-default generation, so a configuration that was only test-activated by hand is not
preserved.

Agents cannot activate host configurations at all and need a human's approval for cloud
mutations. That approval is only a real human gate when the Claude Code session asks for
permissions; under an automatic permission mode the "ask" layer is resolved without a prompt, and
only the deny layer is unconditional.

The hook matches command text, so shell commands that merely *mention* a forbidden command (for
example a heredoc that edits documentation) are also denied; edit such text with file-editing
tools instead.

The switch copies its closure with `nix copy --no-check-sigs`. Paths built on the remote builder
carry no signature, and `nix copy` otherwise rejects them on the workstation side even though the
host trusts `deploy`. The first live switch (ExecPlan 114) failed this way before arming and left
the host untouched. The host still has to trust the deploy user for the copy to be accepted.

The successful workstation helper emits one tab-delimited
`nagare-host-activation committed <closure> fresh-login` receipt only after the fresh SSH login
and the on-host `COMMITTED` response. Inventory execution hashes that exact record and binds it to
the physical GCE instance, expected old closure, new closure, configuration/lock digests, and
activation identity. A matching local flake or version is not completion evidence. Recovery may
retry only when activation never started or the old closure is proven restored; a timer-armed,
unreachable, wrong-instance, or wrong-closure observation remains unresolved, and inventory never
cancels the rollback timer merely to advance a transaction.

## Amendment — 2026-09-13: agent guard removed

The operator removed `.claude/hooks/guard_host_mutation.py` and `.claude/settings.json` (commit
`60a5c47`). The hook's per-command approval prompts made live work impractical. Recovering
`nagare-01` in ExecPlans 114, 116, and 118 involved many hook prompts on top of the harness's own
permission prompts. Three layers remain, and each still stops the original incident on its own:

- the fixture refuses activation;
- every switch reverts itself unless a fresh login proves access;
- the serial-console boot menu provides break-glass access.

`CLAUDE.md` keeps the rules in prose: only `just host-switch` changes a host, and cloud mutations
need the operator's go-ahead for a rehearsed, bounded sequence. Nothing mechanically blocks an
agent from running `nixos-rebuild` or `switch-to-configuration` any more. Layers 2 and 3 are
what make such a mistake recoverable. The Consequences above that describe the hook's prompts
and text matching no longer apply.
