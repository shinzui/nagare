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
- [ ] Milestone 3: update operator documentation and ADR context, then pass focused, installed, and
  full native validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: The plan's root-level `cabal test nagarectl-test` command cannot discover the
  package because the Cabal project lives under `cli/nagarectl`.
  Evidence: the command reported `No cabal.project file`; running it from `cli/nagarectl` with
  `nix develop ../..` passed all 16 focused `Nagare.Host` tests.

- Observation: `shellcheck` is not present in the ordinary developer shell, so direct invocation
  cannot be a focused validation command without adding an ad hoc tool environment.
  Evidence: `nix develop -c shellcheck ...` reported `exec: shellcheck: not found`; the hermetic
  `host-switch-identity` derivation passed with its declared runtime tools.

- Observation: The existing clone-free upgrade fixture stored an empty legacy `host.nix`; the new
  fail-closed preflight correctly rejected that fixture until it declared `local-nagare`.
  Evidence: after making the fixture identity explicit, the installed `nagare-clone-free-platform`
  check completed a `labs` upgrade with ambient `prod-nagare`, recorded only `labs-nagare` Nix/SSH
  calls, left `prod` pinned to `0.0.0`, and rejected a duplicate `hostName` before host evaluation.


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Nagare gives a cloud host three identities that happen to be equal in older contexts but are not
interchangeable. `NAGARE_INSTANCE_NAME` is the GCE resource name used with `gcloud compute`. The
generated NixOS flake exports `nixosConfigurations.<hostName>`. NixOS also installs that `hostName`
as the machine and Tailscale node name, which is the logical SSH target on the tailnet. A context may
therefore keep instance `nagare-01` while using host `labs-nagare`.

`cli/nagarectl/src/Nagare/Host/Config.hs` owns the generated host configuration.
`readContextHostName :: ContextName -> IO (Either Text Text)` reads the exact `hostName = "...";`
assignment from `${XDG_CONFIG_HOME}/nagare/hosts/<context>/host.nix` and rejects missing or multiple
assignments. `stageHostFlake` prepares the target release in a transaction workspace, but it
preserves `host.nix`, so the validated identity remains stable across the upgrade.

`scripts/host-switch.sh` resolves `NAGARE_HOST_FLAKE`, then currently defaults
`NAGARE_HOST_ATTR` from `NAGARE_INSTANCE_NAME` and unconditionally builds its SSH target from
`NAGARE_INSTANCE_NAME`. That makes `CONFIG_REF` point at the wrong flake attribute and every `nix
copy`, rollback arm, activation, and verification connection point at the wrong tailnet name.
`nixos/lib/nagare-safe-switch-client.sh` correctly uses the target it is given; do not duplicate
identity selection there.

`cli/nagarectl/app/Main.hs` constructs `UpgradeOps` in `upgradeOps`. Its `HostApply` branch sets only
`NAGARE_HOST_FLAKE` before invoking the payload's `scripts/host-switch.sh`, even though the same file
already imports `readContextHostName` for kubeconfig fetch and cluster guarding. Resolve the host
name once for the selected `ActiveTarget` and pass it as child-process environment owned by the
transaction. Also expose the same read through `nagarectl host name` so direct `just host-switch`
resolves correctly without an upgrade orchestrator. `cli/nagarectl/test/HostSpec.hs` covers parsing
and generated names;
`cli/nagarectl/test/PlatformSpec.hs` covers upgrade phase ordering and resume; the installed
`nix/checks/scripts/nagare-clone-free-platform.sh` fixture already creates `prod` and `labs` host
configurations with shared instance `nagare-01` and distinct generated names.

[ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) explicitly separates
the GCE instance and context-owned OS/tailnet identities and makes `host.nix` authoritative.
[ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) requires every host activation
to flow through the self-reverting switch and fresh-login verification; preserve that sequence.
[ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) makes the
upgrade host phase reuse the guarded script. No cross-repository ADR governs this fix. The live
origin is `mori://tan/tan-ng-labs/docs/validate-the-labs-nagare-cluster-before-real-use`.


## Plan of Work

Milestone 1 makes the shared CLI/shell boundary unambiguous. Add `nagarectl host name` in
`cli/nagarectl/app/Main.hs`; it selects an optional `--context`, calls `readContextHostName`, prints
only the validated name by default, and offers a stable JSON object for automation. In
`scripts/host-switch.sh`, resolve the generated name through that command after resolving the host
flake. Derive `HOST_ATTR` from explicit `NAGARE_HOST_ATTR` or the validated name and derive the SSH
host portion from explicit `NAGARE_SSH_HOST`, then `NAGARE_HOST_ATTR`, then the validated name. Do
not fall back to `NAGARE_INSTANCE_NAME`. Make dry-run output label all three identities: GCE
instance, Nix attribute, and SSH target. Add `scripts/test-host-switch-identity.sh`,
register it as the `host-switch-identity` Nix check, and use recording `nix`/SSH commands with
instance `nagare-01`, attribute `labs-nagare`, and SSH host
`labs-nagare`; assert no executed argument contains `deploy@nagare-01` or
`nixosConfigurations.nagare-01`. This milestone is accepted when the script's dry run and recorded
execution use only the generated identity outside the informational GCE line.

Milestone 2 wires the transaction to that boundary. In `cli/nagarectl/app/Main.hs`, read the selected
context's generated host name through `readContextHostName` while preparing `upgradeOps`; propagate a
clear error before any apply phase if it cannot be proven. In `runPhase HostApply`, set
`NAGARE_HOST_FLAKE`, `NAGARE_HOST_ATTR`, and `NAGARE_SSH_HOST` in the child environment, replacing
rather than inheriting ambient identity values. If the existing one-variable `withEnvironment`
helper becomes awkward, add a small bracketed multi-variable helper that restores every prior value
after the child exits. Keep `NAGARE_INSTANCE_NAME` unchanged for cloud operations. Add Haskell tests
for missing/ambiguous host configuration and a transaction-facing regression that captures the
environment supplied to the host process. Extend the clone-free platform fixture's `labs`/`prod`
scenario so both contexts retain instance `nagare-01`, the `labs` upgrade stages only
`labs-nagare`, and a seeded sibling named `nagare-01` receives zero recorded calls.

Milestone 3 makes the distinction operable. Update `docs/user/upgrades.md`,
`docs/user/day-2-host-changes.md`, `docs/user/reference.md`, and the multi-cluster guide where needed
to define the three identities and document `NAGARE_SSH_HOST` as a logical tailnet destination, not
a GCE override. Update `[Unreleased]` in `CHANGELOG.md`. Amend ADR 5 with the transaction propagation
rule if it is not already entailed clearly; amend ADR 11 only if the direct switch contract changes
durably. Record final evidence in Outcomes & Retrospective and run all focused and native checks.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/nagare` and preserve unrelated worktree changes:

```bash
git status --short
sed -n '25,125p' scripts/host-switch.sh
sed -n '2960,3050p' cli/nagarectl/app/Main.hs
sed -n '60,120p' cli/nagarectl/src/Nagare/Host/Config.hs
sed -n '230,330p' cli/nagarectl/test/PlatformSpec.hs
```

Format and run the focused suite after the Haskell changes:

```bash
nix develop -c fourmolu -i cli/nagarectl/app/Main.hs cli/nagarectl/test/PlatformSpec.hs cli/nagarectl/test/HostSpec.hs
(cd cli/nagarectl && nix develop ../.. -c cabal test nagarectl-test)
nix develop -c ./scripts/check-haskell-style.sh
```

Run the new host-switch fixture and installed boundary. The successful evidence should have this
shape:

```bash
bash scripts/test-host-switch-identity.sh
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).host-switch-identity
```

```text
GCE instance: nagare-01
attribute: labs-nagare
target host: deploy@labs-nagare
wrong-host calls: 0
```

Then run:

```bash
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).nagare-clone-free-platform
just user-documentation-validate
nix flake check --print-build-logs
```

Every implementation commit must be conventional and end with:

```text
ExecPlan: docs/plans/141-separate-generated-host-identity-from-gce-instance-identity-in-upgrades.md
```


## Validation and Acceptance

Create two isolated contexts, `labs` and `prod`, whose stored target profiles both name GCE instance
`nagare-01`. Give their generated host modules `labs-nagare` and `prod-nagare`, and seed a recording
SSH endpoint for a sibling logically named `nagare-01`. Plan and apply the `labs` transaction with
all provider, Nix, and SSH effects replaced by recording fakes. The host phase must evaluate
`nixosConfigurations.labs-nagare`, copy to `deploy@labs-nagare`, arm/activate/verify/commit through
that same logical target, and never issue any request containing the sibling identity. The `prod`
fixture must analogously stay on `prod-nagare`.

A missing `host.nix`, unreadable file, absent assignment, duplicate assignment, or ambient
`NAGARE_HOST_ATTR=prod-nagare` while upgrading `labs` must refuse before host mutation and name the
selected context. Existing safe-switch auto-rollback checks must continue to pass, proving the fix
changes only identity selection and not the safety protocol. Haskell tests, shellcheck, installed
clone-free validation, user-documentation validation, and all native flake checks must pass.


## Idempotence and Recovery

Identity resolution is read-only and can be retried. A failed preflight leaves the transaction and
host unchanged. Once the generated `host.nix` is repaired, `platform upgrade --apply --resume`
re-enters the host phase with the same staged flake and newly proven name. The switch itself remains
self-reverting: failure before fresh-login verification never commits the new boot generation. Test
fixtures must use recording transports and temporary XDG roots; they must never resolve or contact
real tailnet nodes. Do not rename a live GCE instance or host as part of this fix.


## Interfaces and Dependencies

Retain `Nagare.Host.Config.readContextHostName :: ContextName -> IO (Either Text Text)` as the single
parser and validator for generated host identity. `nagarectl host name [--context CONTEXT] [--json]`
is the public read-only projection used by shell workflows. If orchestration needs a structured
value, define a small record in `cli/nagarectl/src/Nagare/Host/Config.hs`, for example:

```haskell
data HostSwitchIdentity = HostSwitchIdentity
  { hostAttribute :: !Text
  , sshHost :: !Text
  }
```

Both fields are initialized from the validated generated host name for an ordinary upgrade. The
shell boundary consumes `NAGARE_HOST_FLAKE`, `NAGARE_HOST_ATTR`, `NAGARE_SSH_HOST`,
`NAGARE_SSH_USER`, and `NAGARE_INSTANCE_NAME`; only the first three select Nix or SSH operations.
`NIX_SSHOPTS` remains the supported lower-level transport mapping for a verified HostName or
HostKeyAlias and must not change the logical identity printed and audited by the transaction.
