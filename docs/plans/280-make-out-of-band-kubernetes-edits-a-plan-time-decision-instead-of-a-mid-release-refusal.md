---
id: 280
slug: make-out-of-band-kubernetes-edits-a-plan-time-decision-instead-of-a-mid-release-refusal
title: "Make out-of-band Kubernetes edits a plan-time decision instead of a mid-release refusal"
kind: exec-plan
created_at: 2026-11-23T17:09:33Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-23T17:09:33Z
---

# Make out-of-band Kubernetes edits a plan-time decision instead of a mid-release refusal

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

An operator sometimes changes a Nagare-managed Kubernetes object by hand: `kubectl patch`,
`kubectl edit`, `kubectl annotate`. Kubernetes then records that tool as the owner of the fields
it changed (the object's `metadata.managedFields`). Nagare's executor refuses to update an object
whose fields another writer owns, with `KnownNoEffect "Kubernetes object has fields managed by
another writer: kubectl-patch"`, before it writes anything. The refusal is right; when and where it
happens is the problem.

On 2026-11-23 the work intranet (`mori://tan/tan-ng-labs`, context `intranet`) had nine backup
CronJobs whose `spec.schedule` had been staggered with `kubectl patch`. The v0.28.0 release
candidate's transition applied stage 1 (the NixOS host) and then refused at the first CronJob in
stage 2. Nagare offers a reviewed field takeover (finding F37, `--take-over-fields`) only on
`app deploy` and inside the hand-annotated-route stage, so there was no reviewed way to clear the
foreign owner on platform objects. The operator approved a hand JSON patch that removed the
`kubectl-patch` entries from `managedFields`, and the release was rerun.

After this plan:

1. Every planning command that can update a Kubernetes object accepts the same reviewed takeover
   opt-in, `--take-over-fields`: `platform transition plan`, `platform bootstrap plan` and
   `inventory plan`. The review names each object and each writer it takes over from, and the
   apply takes the fields back exactly as `app deploy --take-over-fields` does today.
2. Without the opt-in, a plan that would update an object owned in part by another writer refuses
   at plan time, before any stage is applied. The refusal names each object, writer and field, and
   gives the two remedies: replan with `--take-over-fields`, or declare the change (a context value
   or overlay) so Nagare renders it.
3. `just release-candidate X.Y.Z --take-over-fields` forwards the opt-in to the transition plan.
   Without it, the candidate stops at plan time and names the objects, instead of after the host
   stage.

The operator never needs to edit `managedFields` by hand again. An out-of-band edit becomes a
decision made at plan time: take it over, or declare it.


## Progress

- [ ] M1: `platform transition plan`, `platform bootstrap plan` and `inventory plan` accept
  `--take-over-fields`. On a local context, a Deployment patched with `kubectl patch` plans with
  the writer named in the review summary, applies, and afterwards lists only `nagare-inventory`
  (and status writers) in `managedFields`. Unit tests cover the flag reaching the plan registry for
  each command.
- [ ] M2: without the opt-in, the same plans refuse at plan time naming object, writer and fields;
  a plan with no foreign owners is byte-identical to today's. The release harness reports the
  refusal from the plan log and accepts `--take-over-fields`, which it records in the run index.
- [ ] M3: `docs/runbooks/inventory-operations.md` ("Repair configuration drift"),
  `docs/runbooks/releases.md` and `docs/user/reference.md` describe the plan-time refusal and the
  opt-in for every planning command; the F37 note that `inventory plan` lacks the opt-in is
  removed. Landed with the full gate green.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Do not import out-of-band changes into the journal as accepted state.
  Rationale: the journal records what a reviewed declaration compiled to. A journaled hand edit
  that the source cannot express (the intranet's `5-59/15` schedules, before EP-238 M3) would be
  reverted by the next compile and would carry bytes no review produced and no test covers. An
  edit becomes durable only through a declared knob. The operator agreed on 2026-11-23.
  Date: 2026-11-23.

- Decision: The release harness never takes over fields unless the operator passes
  `--take-over-fields` to `just release-candidate`; the default is the plan-time refusal.
  Rationale: a silent takeover during a release would revert an operator's deliberate edit without
  their decision.
  Date: 2026-11-23.

- Decision: The plan-time refusal moves the executor's existing check earlier; it adds no new
  condition. An object with only status writers (`k3s`, `kube-controller-manager`) plans as today.
  Rationale: the operator's rule against adding checks (CLAUDE.md, 2026-10-10); the check already
  exists at apply time, where it fires after earlier stages have changed the host.
  Date: 2026-11-23.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Terms. A *field manager* is the name Kubernetes records for whoever last set a field, kept in
`metadata.managedFields`; Nagare applies as `nagare-inventory` with server-side apply. A *foreign*
manager is any other writer of a non-status field. A *review* is the saved plan (`review.json`)
that `inventory apply DIR --yes` executes; a *stage* is one review inside a release transition.

Where the pieces are:

- `cli/nagarectl/src/Nagare/Inventory/KubernetesConfiguration.hs` holds the checks:
  `foreignFieldManagers`, `confirmReviewedFieldTakeover` (a live foreign entry is accepted only when
  the review recorded it; the message "Kubernetes object has fields managed by another writer: …"),
  `confirmTakeoverSettled` and `takeoverSettlementPatch`, which removes Nagare-applied fields from
  each recorded writer's entry when the forced apply left them co-owned (EP-273).
- `cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs`: `mkKubernetesAdapterWithFieldTakeover`
  and `prepareTakeover`, which, at plan time and only for `UpdateResource`, read the live object and
  record a `FieldTakeover` (UID, resourceVersion, foreign entries) in the mutation; the summary line
  "takes over fields from …" is built near the end of the module.
- `cli/nagarectl/app/Nagare/Cli/Inventory/Planning.hs`: `inventoryPlanRegistryWithTakeover :: Bool -> …`
  is the opt-in; `inventoryPlanRegistryWithNative` passes `False`.
- `cli/nagarectl/app/Nagare/Cli/Bootstrap/Sequence.hs`, `planNextStage`: both `platform bootstrap
  plan` and `platform transition plan` (mode `ReleaseTransition`) plan here. The main candidate uses
  `inventoryPlanRegistryWithNative`; only the protected-route refresh uses
  `inventoryPlanRegistryWithTakeover True`.
- `cli/nagarectl/app/Nagare/Cli/Commands/Application.hs` threads `appOptions ^. #takeOverFields`
  into the registry for `app deploy`; its parser flag is in
  `cli/nagarectl/app/Nagare/Cli/Parser/Application.hs`. The platform and inventory parsers are
  `cli/nagarectl/app/Nagare/Cli/Parser/Platform.hs` and `Parser/Inventory.hs`.
- `cli/nagare-harness/src/Nagare/Harness/Release/Intranet.hs`, `converge`: plans each stage with
  `platform transition plan --out … --summary …`, applies it, and refuses on the first failure.

Related work. `docs/plans/277-make-the-vm-resize-path-and-store-status-work-on-inventory-contexts.md`
fixes `inventory store status`, which reports `unsupported-schema` and omits `activeTransaction`
for every schema-2 head. On 2026-11-23 that made the harness's "no active transaction" check pass
while `tx-61b993f8…` was active. This plan relies on 277's first milestone and does not repeat it.

ADRs. [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md): a stopped
transaction is closed by per-operation proof; a plan-time refusal leaves nothing to close.
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md): an open
transition admits only its target payload; a plan-time refusal before the first stage opens no
transition marker. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md):
unit tests find defects, the local native run confirms.


## Plan of Work

M1. Add `--take-over-fields` to the `platform transition plan`, `platform bootstrap plan` and
`inventory plan` parsers. Thread the Bool to `planNextStage` and to the inventory plan command, and
use `inventoryPlanRegistryWithTakeover takeOver` wherever those commands now use
`inventoryPlanRegistryWithNative`. The route-refresh branch keeps `True`. Nothing in the adapter
changes: `prepareTakeover` already records the entries and the apply already honours them. Unit
tests assert that each parser sets the flag and that the registry receives it.

M2. When the flag is off, make planning fail for an `UpdateResource` whose live object has a foreign
manager of a field the declaration sets. Reuse the live read `prepareTakeover` does (it already
runs per update target when the flag is on): run it always, and with the flag off turn a non-empty
`others` into a plan error naming the object, each manager and its fields, and both remedies.
Objects without foreign owners produce the same review bytes as today; a test pins this with an
existing review fixture. In the harness, `converge` already prints the plan log's last lines on a
refused plan; add `--take-over-fields` to the candidate's options and pass it to
`platform transition plan`, and record it in the stage's index entry.

M3. Documentation as listed in Progress, then `just gate-fast`, `just land`, full gate green.


## Concrete Steps

From the repository root, on a local context (`just local-up`):

```bash
nagarectl platform bootstrap plan --out /tmp/ep280-1 && nagarectl inventory apply /tmp/ep280-1 --yes
kubectl -n nagare-system patch deploy nagare-access --type=merge -p '{"spec":{"replicas":2}}'
nagarectl platform bootstrap plan --out /tmp/ep280-2      # M2: refuses, names nagare-access and kubectl-patch
nagarectl platform bootstrap plan --out /tmp/ep280-3 --take-over-fields
jq -r '.operations[].summary' /tmp/ep280-3/review.json | grep 'takes over fields from kubectl-patch'
nagarectl inventory apply /tmp/ep280-3 --yes
kubectl -n nagare-system get deploy nagare-access -o json --show-managed-fields | jq -r '.metadata.managedFields[].manager' | sort -u
```

The patched field must be one Nagare declares (`spec.replicas` here), so the takeover removes the
writer. A field Nagare does not declare stays the writer's, and `confirmTakeoverSettled` stops the
apply ambiguous, as today.


## Validation and Acceptance

M1 is accepted when the last command prints only `nagare-inventory` and status managers, and the
new parser and registry tests pass under `just gate-commit`. M2 is accepted when `/tmp/ep280-2`
refuses with the object, writer and fields named, an unpatched context's plan matches its fixture
byte for byte, and a harness unit test shows `--take-over-fields` reaching `platform transition
plan`. M3 is accepted when the documents are committed and the landed revision's full gate is
green.


## Idempotence and Recovery

Planning is read-only and can be repeated. A takeover review binds the object's UID and
resourceVersion: if the object changes after planning, the apply refuses before writing, and the
operator replans. A plan-time refusal writes nothing and opens no transaction or transition.


## Interfaces and Dependencies

No new libraries. `--take-over-fields` keeps the meaning it has on `app deploy`. The plan error is a
new constructor or message on the existing planning error path; its text names the resource ID, the
Kubernetes address, each manager and its fields. Depends on
`docs/plans/277-make-the-vm-resize-path-and-store-status-work-on-inventory-contexts.md` M1 for a
truthful `inventory store status`.
