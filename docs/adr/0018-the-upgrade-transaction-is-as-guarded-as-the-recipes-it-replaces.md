---
title: "The upgrade transaction is as guarded as the recipes it replaces"
status: accepted
date: 2026-09-13
authors: [shinzui]
related:
  - docs/plans/121-give-operator-pulumi-stack-config-a-context-owned-home-so-guarded-platform-upgrades-are-safe-ship-0-2-1-and-upgrade-tan-nb-exp.md
  - docs/plans/136-apply-reviewed-infrastructure-and-confine-remote-builders.md
  - docs/plans/142-migrate-legacy-namespace-wildcard-certificates-during-upgrades.md
  - docs/plans/143-skip-proven-pulumi-apply-work-when-resuming-upgrades.md
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

## Amendment — 2026-09-14: apply the retained reviewed plan

[ExecPlan 136](../plans/136-apply-reviewed-infrastructure-and-confine-remote-builders.md) strengthens
the Pulumi boundary. Preview and apply no longer compute separate plans. The preview phase invokes
Pulumi once with `--save-plan` and retains a directory bundle containing Pulumi's plan, Nagare's
redacted operation review, and metadata binding both to the context, GCP project, stack, backend,
immutable payload, program/config digest, and Pulumi version. The private bundle is part of the
transaction state, and resume verifies it rather than recomputing it.

The apply phase reruns the platform, ADC, and project guards, verifies all bundle members and
bindings, then invokes `pulumi up --plan ... --yes --non-interactive`. Tampering, changing inputs,
switching context/backend/stack, or changing Pulumi makes the retained plan stale and refuses before
an update. Protected replacement approval is recorded during review and acknowledged again at
apply.

This is a constrained execution boundary, not an atomic transaction. Pulumi may perform a safer
operation than planned and cloud calls still occur over time; a failed update can leave partial
progress. Recovery keeps the unchanged bundle for inspection and retry while its bindings remain
valid. If they do not, the operator creates a new review or upgrade transaction. Deliberate teardown
is a separate guarded command and is never inferred as rollback or recovery.

## Amendment — 2026-09-15: retain and guard Kubernetes migration evidence

[ExecPlan 142](../plans/142-migrate-legacy-namespace-wildcard-certificates-during-upgrades.md)
extends the retained-review boundary to an upgrade's Kubernetes diff. Planning runs the cluster
guard, captures the selected cluster's TLS policy and exact certificate-chain inventory, previews
the desired ConfigMap with server-side diff, and atomically publishes a private
`kubernetes-plan/` bundle. Its metadata binds the transaction, context, immutable payload, and
member digests; planning performs no Kubernetes write.

Kubernetes apply reruns the cluster guard and rejects wrong-context, stale, tampered, permissive, or
ambiguous evidence before mutation. It applies the reviewed selector before the ordinary bootstrap,
then confines cleanup to unchanged reviewed identities. A failed phase retains the old context pin
and the same evidence for a convergent resume. A future Kubernetes mutation added to an upgrade must
either fit this retained-review boundary or document and guard its own equivalent boundary.

## Amendment — 2026-09-15: bind Pulumi completion evidence to the retained review

[ExecPlan 143](../plans/143-skip-proven-pulumi-apply-work-when-resuming-upgrades.md) adds a private
Pulumi apply receipt beside the upgrade's retained plan. Its schema binds transaction, context,
target release, payload, project, stack, backend, Pulumi version, and plan/review digests. Receipt
writes use a private same-directory temporary file and atomic rename. Resume verifies the immutable
local bundle and receipt without consulting Pulumi; only an exact automatic or operator-attested
success skips the provider phase. A known automatic failure may retry the unchanged reviewed plan.

The unavoidable crash window around an external provider is explicit. `started` is durable before
`pulumi up`, so loss of the process before its result is recorded refuses automatic recovery. The
separate `platform upgrade recover-pulumi TRANSACTION --outcome applied|retry --yes` command reruns
the platform, credential, project, bundle, and current stack-identity guards and displays the
reviewed and observed bindings before recording an operator decision. `applied` permits later phases
without another provider call; `retry` permits exactly the next normal resume to consume the same
reviewed plan. Later host and Kubernetes phases also suppress the shared target shell's eager local
stack selection, keeping a proven-success resume provider-independent without weakening commands
that actually execute Pulumi.

## Amendment — 2026-09-25: close coarse Pulumi mutation after inventory admission

The version-one platform upgrade, standalone older Pulumi-plan apply, and
selected-stack destroy do not produce typed component receipts. Before any of
those mutating paths runs, the operator reads the selected context's inventory
head. An accepted or converged scope, retained or collected record, advanced
generation or journal sequence, active executor claim or transaction, or store
migration marker closes the older path. An uninitialized or untouched store
still permits the guarded compatibility workflow. Unknown or unreadable store
state refuses mutation. This is a safety boundary while the component-backed
upgrade and reviewed teardown protocols are incomplete, not evidence that
those protocols have shipped.

## Amendment — 2026-09-26: no in-place upgrade in the first inventory release

The first full inventory release accepts fresh contexts only. The operator
confirmed that the current Nagare contexts and their data can be recreated,
so converting the coarse transaction into component operations is no longer
a release gate. The admission guard above remains mandatory: `platform
upgrade` cannot mutate a context with substantive inventory history. Old
transactions remain inspectable and may be recovered with their original
operator payload outside the fresh inventory-backed release claim. A later
in-place version transition needs a new reviewed design with component
receipts, host committed-closure proof, and a final context pin decision;
the old phase journal is not that proof.
