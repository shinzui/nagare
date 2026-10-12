---
id: 141
slug: separate-generated-host-identity-from-gce-instance-identity-in-upgrades
title: "Separate generated host identity from GCE instance identity in upgrades"
kind: exec-plan
created_at: 2026-09-15T14:04:02Z
intention: "intention_01m2jp3520endstktsk72zc1q9"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-15T14:04:02Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T15:09:54Z
      mode: "implement"
      note: "Implement generated host identity separation across switch and upgrades"
---

# Separate generated host identity from GCE instance identity in upgrades

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [141-separate-generated-host-identity-from-gce-instance-identity-in-upgrades.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/141-separate-generated-host-identity-from-gce-instance-identity-in-upgrades.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Upgrading a context whose Google Compute Engine (GCE) virtual-machine name differs from its NixOS
and Tailscale host name evaluates and contacts only that context's generated host identity. The GCE
instance name remains reserved for Google Cloud API and IAP operations; it is never reused as a Nix
attribute or tailnet destination. The current failure and wrong-host risk are recorded in
[BUG-2](../bug-reports/upgrade-host-switch-confuses-instance-and-host-names.md).

After this change, a `labs` context with instance `nagare-01` and generated host `labs-nagare`
evaluates `nixosConfigurations.labs-nagare` and connects to `deploy@labs-nagare`. A regression with
a sibling node actually named `nagare-01` proves that evaluation, closure copy, activation, and
fresh-login verification never address that sibling during the upgrade host phase.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-15T15:16:38Z) Milestone 1: defined and tested an explicit host-switch input
  contract that keeps the Nix attribute, SSH/tailnet destination, and GCE instance name separate.
- [x] (2026-09-15T15:25:12Z) Milestone 2: made `nagarectl platform upgrade` read the staged
  context's validated generated host name and pass it to every host-switch operation.
- [x] (2026-09-15T15:30:00Z) Milestone 3 documentation: updated operator guidance, changelog,
  bundle logs, and ADR 5; strict user-documentation validation passed.
- [x] (2026-09-15T15:33:29Z) Milestone 3 validation: passed the full Haskell, style,
  focused/installed Nix, and native flake checks and recorded the retrospective.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: The plan's root-level `cabal test nagarectl-test` command cannot discover the
  package because the Cabal project lives under `cli/nagarectl`.
  Evidence: the command reported `No cabal.project file`; running it from `cli/nagarectl` with
  `nix develop ../..` passed all 18 focused `Nagare.Host` tests.

- Observation: `shellcheck` is not present in the ordinary developer shell, so direct invocation
  cannot be a focused validation command without adding an ad hoc tool environment.
  Evidence: `nix develop -c shellcheck ...` reported `exec: shellcheck: not found`; the hermetic
  `host-switch-identity` derivation passed with its declared runtime tools.

- Observation: The existing clone-free upgrade fixture stored an empty legacy `host.nix`; the new
  fail-closed preflight correctly rejected that fixture until it declared `local-nagare`.
  Evidence: after making the fixture identity explicit, the installed `nagare-clone-free-platform`
  check completed a `labs` upgrade with ambient `prod-nagare`, recorded only `labs-nagare` Nix/SSH
  calls, left `prod` pinned to `0.0.0`, and rejected a duplicate `hostName` before host evaluation.

- Observation: The native validation matrix exercises the new identity boundary through both unit
  and installed-script paths without requiring live cloud or tailnet state.
  Evidence: `nix flake check --print-build-logs` passed all aarch64-darwin flake checks, including
  all 554 Haskell tests and `shellcheck-scripts`; direct builds of `host-switch-identity` and
  `nagare-clone-free-platform` passed their focused installed-path rehearsals.

## Decision Log

Record every decision made while working on the plan.

- Decision: Keep `NAGARE_HOST_ATTR` as the explicit NixOS-configuration selector and introduce
  `NAGARE_SSH_HOST` as the explicit network destination. During an upgrade, set both from
  `readContextHostName`; keep `NAGARE_INSTANCE_NAME` available only for GCE/IAP code.
  Rationale: A generated host currently uses one validated name for its flake attribute, NixOS
  `networking.hostName`, and Tailscale identity, but SSH transport overrides may legitimately map
  that logical name to another address. Two explicit inputs preserve that flexibility without
  conflating either value with the project-scoped VM resource name.
  Date: 2026-09-15.

- Decision: Add a read-only `nagarectl host name` command and make direct `host-switch.sh`
  invocations default from that command, never from `NAGARE_INSTANCE_NAME`.
  Rationale: `just host-switch` and the upgrade both reach the same script. Fixing only the
  transaction environment would leave the documented day-two command unsafe for contexts created
  under the distinct-name policy. The CLI already owns the only validated `host.nix` parser, so the
  shell should query it rather than duplicate parsing.
  Date: 2026-09-15.

- Decision: Fail before entering the host phase when the context-owned `host.nix` is missing,
  unreadable, or ambiguous; do not fall back to `NAGARE_INSTANCE_NAME` in upgrade orchestration.
  Rationale: `Nagare.Host.Config.readContextHostName` already treats the generated module as the
  source of truth. Falling back recreates the wrong-host hazard precisely when identity cannot be
  proven.
  Date: 2026-09-15.

- Decision: Preserve explicit `NAGARE_HOST_ATTR` and `NAGARE_SSH_HOST` overrides for direct
  troubleshooting, but have `nagarectl platform upgrade` overwrite inherited ambient values with
  the transaction's validated context identity.
  Rationale: An ambient value from another context must not redirect a reviewed transaction. A
  direct `host-switch.sh` recovery can still deliberately select a logical destination after the
  operator independently verifies it.
  Date: 2026-09-15.

- Decision: Parse the transaction's staged `host.nix` when constructing upgrade operations rather
  than rereading the mutable context-owned module at apply time.
  Rationale: The staged module is the reviewed Nix input and survives resume. Binding the child
  environment to it prevents an operator edit between planning and apply from selecting a host
  name that does not match the configuration being evaluated and activated.
  Date: 2026-09-15.

- Decision: Amend ADR 5, but not ADR 11, for this change.
  Rationale: ADR 5 owns the durable boundary between GCE and context-owned OS/tailnet identity and
  now records how direct and transactional switches propagate it. ADR 11's guarded activation,
  fresh-login verification, rollback timer, and commit protocol are unchanged.
  Date: 2026-09-15.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The upgrade and direct-switch paths now keep all three host identities explicit. The GCE instance
name remains available for cloud and IAP operations, while the generated host name selects the Nix
configuration and, by default, the SSH/tailnet destination. `nagarectl platform upgrade` derives
that logical identity from the reviewed staged `host.nix`, replaces potentially stale ambient
values for the child switch, and refuses missing, unreadable, absent, or duplicate declarations
before host evaluation. Direct `just host-switch` use obtains the same validated identity through
the new read-only `nagarectl host name` command while retaining deliberate troubleshooting
overrides.

The regression evidence covers the original wrong-host scenario: `prod` and `labs` share GCE
instance `nagare-01`, `prod` has generated host `prod-nagare`, and the upgraded `labs` context has
generated host `labs-nagare`. Even with an ambient `prod-nagare` override and a sibling named
`nagare-01`, the installed rehearsal records evaluation, closure copy, activation, and verification
only against `labs-nagare`; neither sibling is contacted, and the `prod` context remains unchanged.
An ambiguous staged identity stops before any host evaluation.

Validation passed with 18 focused host tests, the full 554-test Haskell suite, Haskell style, strict
user-documentation validation, the standalone and installed host-switch identity checks, the
clone-free platform-upgrade rehearsal, and `nix flake check --print-build-logs`. ADR 5 now records
the durable identity and propagation boundary. ADR 11 required no change because the guarded
activation protocol itself did not change. No implementation gaps remain for this plan.

