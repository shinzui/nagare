---
title: "The upgrade transaction is as guarded as the recipes it replaces"
status: accepted
date: 2026-09-13
authors: [shinzui]
related:
  - docs/plans/121-give-operator-pulumi-stack-config-a-context-owned-home-so-guarded-platform-upgrades-are-safe-ship-0-2-1-and-upgrade-tan-nb-exp.md
  - docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md
  - docs/adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md
  - docs/adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md
  - docs/adr/0014-the-active-context-owns-the-vm-shape.md
---

# ADR 18 — The upgrade transaction is as guarded as the recipes it replaces

## Status

Accepted, 2026-09-13. Implemented by
[ExecPlan 121](../plans/121-give-operator-pulumi-stack-config-a-context-owned-home-so-guarded-platform-upgrades-are-safe-ship-0-2-1-and-upgrade-tan-nb-exp.md).

## Context

ADR 6 made `nagarectl platform upgrade` the operator's path between releases. It plans with
`pulumi-preview` and applies with `pulumi-apply`, `host-apply`, `kubernetes-apply`,
`cluster-stamp`, and `context-commit`. After ADR 6, ADR 9 added the project assertion and ADR 14
added the instance-replacement guard, but both were wired only into the `justfile` recipes and
their `nagarectl` subcommands. In Nagare 0.2.0 the upgrade's preview was a bare
`pulumi preview`, and its apply was `pulumi up --yes --skip-preview`. Nothing checked the project
or classified the plan that the transaction executed. Those phases also ran in a payload workspace
without the context's stack configuration (see the ADR 13 amendment). An audit before upgrading
`tan-nb-exp` found this combination, which could have replaced a production VM.

## Decision

Every mutating path that the upgrade transaction runs must carry at least the guards of the
recipe it replaces.

- **Pulumi phases.** For a cloud context, `pulumi-preview` and `pulumi-apply` each run the
  project guard (`projectGuardInputsFor` with `projectGuardVerdict`) and then the
  protected-resource replacement guard (`instanceReplacementGuard`). Only after both pass does
  `pulumi-apply` run `pulumi up --yes`, which previews again. It never passes `--skip-preview`.
  A replacing plan fails the phase unless `NAGARE_ALLOW_VM_REPLACEMENT=1` is set. The phase
  evidence records both verdicts.
- **Host phase.** `host-apply` continues to use the self-reverting `scripts/host-switch.sh`
  (ADR 11).
- **Cluster phase.** `kubernetes-apply` continues to use `just cluster-bootstrap`, which renders
  the context-owned ACME identity or refuses (ADR 10).

A new guard added to a recipe must be added to the matching transaction phase in the same change.

## Consequences

Plan and apply each run a guarded preview, so an upgrade takes longer. A guard refusal leaves a
failed, resumable transaction and the old context pin. `platform upgrade` in 0.2.0 must not be
used on real cloud contexts; the 0.2.1 release notes and the 0.2.0 release description say so.
The guards are implemented once in `cli/nagarectl/app/Main.hs` and shared by the subcommands and
the transaction, so their behavior cannot drift between the two paths.
