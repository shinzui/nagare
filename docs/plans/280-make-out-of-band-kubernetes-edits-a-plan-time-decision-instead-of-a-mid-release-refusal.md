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
  reviews:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-24T05:35:55Z
      verdict: "changes-requested"
      note: "Stages are planned one at a time, so the M2 refusal still lands after the host stage; M2 also reaches every Kubernetes planner; Concrete Steps name a Deployment that does not exist"
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-24T05:38:42Z
      mode: "update"
      note: "Add the transition preflight of the platform stage (M3), scope the refusal and the flag, fix Concrete Steps to the shomei Deployment"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-24T06:05:35Z
      mode: "implement"
      note: "M1 to M3 code and unit tests, M4 documents; native confirmation and landing open"
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

1. The platform planning commands accept the reviewed takeover opt-in that `app deploy` has,
   `--take-over-fields`: `platform transition plan`, `platform bootstrap plan` and
   `inventory plan`. The review names each object and each writer it takes over from, and the
   apply takes the fields back exactly as `app deploy --take-over-fields` does today.
2. Without the opt-in, any plan that would update an object owned in part by another writer
   refuses at plan time, before the review is written. This holds for every command that plans a
   Kubernetes update, because the refusal lives in the shared Kubernetes adapter. The refusal names
   each object, writer and field, and gives the remedies: replan with `--take-over-fields` on a
   command that accepts it, or declare the change (a context value or overlay) so Nagare renders
   it.
3. A release transition refuses before its first stage is applied. When `platform transition plan`
   is about to plan a stage that precedes the platform stage (the host stage, for example), it
   first prepares the platform stage against the live cluster and stops on a foreign owner. The
   host is not touched.
4. `just release-candidate X.Y.Z --take-over-fields` forwards the opt-in to the transition plan.
   Without it, the candidate stops at the first plan and names the objects, instead of after the
   host stage.

The operator never needs to edit `managedFields` by hand again. An out-of-band edit becomes a
decision made at plan time: take it over, or declare it.


## Progress

- [ ] M1: `platform transition plan`, `platform bootstrap plan` and `inventory plan` accept
  `--take-over-fields`. On a local context, the `shomei` Deployment patched with `kubectl patch`
  plans with the writer named in the review summary, applies, and afterwards lists only
  `nagare-inventory` (and status writers) in `managedFields`. Unit tests cover the flag reaching
  the plan registry for each command.
  Code done 2026-11-23 (commit 224a34ff): the three parsers carry the flag (`--help` shows it) and
  it reaches `inventoryPlanRegistryWithTakeover`. Open: the native run. No local context on this
  machine is bootstrapped on this payload (FRIC-22).
- [ ] M2: without the opt-in, a plan that updates an object with a foreign owner refuses at plan
  time naming object, writer and fields; a plan with no foreign owners is byte-identical to
  today's; an adapter built without a live-object reader behaves as today.
  Code and unit tests done 2026-11-23 (commit 224a34ff): `InventoryKubernetesFieldTakeoverSpec`,
  "planning without the opt-in refuses a foreign owner…" and "an adapter without a live reader…",
  pass under `just gate-commit` (green in 159 s). Open: the native refusal (`/tmp/ep280-2`).
- [ ] M3: `platform transition plan` prepares the platform stage before it plans an earlier stage
  and refuses on a foreign owner, with no review written. The release harness accepts
  `--take-over-fields`, passes it to the intranet's transition plan and records it in the run
  index.
  Code and unit tests done 2026-11-23 (commit 224a34ff): "a stage ahead of the platform stage is
  planned only when the platform plan refuses no foreign owner" (nagarectl) and
  "--take-over-fields reaches every stage's plan and its index entry" (nagare-harness, 128 tests
  pass). Open: the bounded prototype on a local context (FRIC-22).
- [ ] M4: `docs/runbooks/inventory-operations.md` ("Repair configuration drift"),
  `docs/runbooks/releases.md` and `docs/user/reference.md` describe the plan-time refusal, the
  transition preflight and which commands accept the opt-in; the F37 note that `inventory plan`
  lacks the opt-in is removed. `just mutation-check` passes on the range, and the change is landed
  with the full gate green.
  Documents written 2026-11-23. Open: the mutation check's result, `just gate-fast`, `just land`.


## Surprises & Discoveries

- The CLI's parsers, `planNextStage` and the plan registry are in the executable's private `app/`
  tree, which no test suite imports. M1's "parser sets the flag" tests and M3's "transition whose
  pending stage is the host stage" test cannot be written there. The preflight's decision moved to
  the library (`afterForeignOwnerPreflight`) so it has a unit test; the flag's path through the
  parsers is covered by the native run alone. See the Decision Log.
- The transition cost tests pin a plan's Kubernetes reads. The plan-time check costs one
  `kubectl get --show-managed-fields` per updated object, because the planning epoch's grouped
  reads omit managed fields. Evidence: `TransitionCostSpec`, "sweep" plan went from 2 transport
  reads to 3, "four" (three updates) from 2 to 5. The budgets were raised by that read.
- `prepareInventoryCandidateWithRetirementsPayload` publishes the review to the inventory store
  before it returns it. A preflight built on it would have published a platform review on every
  host-stage plan, so the preflight uses a variant that stops before publication.


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
  condition. It reuses `foreignFieldManagers` unchanged: any foreign owner of a non-status field on
  an object the plan updates refuses, whether or not the declaration sets that field. An object
  with only status writers or proved controller fields plans as today.
  Rationale: the operator's rule against adding checks (CLAUDE.md, 2026-10-10); the check already
  exists at apply time, where it fires after earlier stages have changed the host.
  Date: 2026-11-23.

- Decision: A release transition preflights the platform stage. Before it plans a stage that
  precedes the platform stage, `planNextStage` prepares the platform candidate against the live
  cluster, discards the review, and stops only on a foreign-owner refusal. Any other preflight
  failure is ignored and left to the platform stage's own plan.
  Rationale: the transition plans one stage at a time and the host stage comes first, so a refusal
  in the platform stage's own plan would still land after the host changed, as on 2026-11-23. The
  operator chose the preflight over scanning every accepted object (a new condition that would
  block a release over an object it does not update) and over narrowing the promise. Other
  failures are ignored because the platform stage may not be plannable before the host stage, and
  that must not become a new way to stop a release.
  Date: 2026-11-23.

- Decision: The refusal applies to every command that plans a Kubernetes update, but only
  `platform transition plan`, `platform bootstrap plan`, `inventory plan` and `app deploy
  --save-plan` accept `--take-over-fields`.
  Rationale: the check is in the shared adapter, and those other commands (database, task, worker,
  site, broker, environment, restore, backup) already refuse at apply time with no takeover, so
  refusing before the review is written loses nothing. Adding the flag to about 25 commands is not
  needed for the release path. The refusal text names the commands that accept the flag.
  Date: 2026-11-23.

- Decision: `nagare-harness`'s transition drill (`Release/TransitionDrill.hs`) never passes
  `--take-over-fields`.
  Rationale: it runs on a disposable context that nobody patches by hand.
  Date: 2026-11-23.

- Decision: The preflight's decision is a library function,
  `Nagare.Inventory.ForeignOwnerPreflight.afterForeignOwnerPreflight`, which takes the platform
  plan's refusal and the stage to plan. `planNextStage` supplies both. The parser and registry
  wiring has no unit test.
  Rationale: tests import only the library; the wiring is three positional arguments that the
  native run exercises. A test that imports the executable's modules would need a new test
  component, which is more ceremony than the risk.
  Date: 2026-11-23.

- Decision: The preflight runs with the contract sink off and catches a command refusal (an exit)
  as well as a returned refusal. When it is skipped, one `note:` line on stderr says so.
  Rationale: `buildPlatformCandidate` and the store calls refuse by exiting, and "ignore every
  other outcome" has to cover them. A refusal that exits has already printed its own line, so the
  note tells the reader that line did not stop the plan.
  Date: 2026-11-23.

- Decision: The preflight is skipped when `--take-over-fields` is given, and it covers the stages
  `planNextStage` plans. The transition's cloud-foundation stage, planned in
  `planTransitionStage` before `planNextStage`, has no preflight.
  Rationale: with the opt-in the platform stage records the takeover, so there is nothing to
  refuse. The foundation stage is pending only after a delegation or context edit with no
  bootstrap since, and it changes no host; a refusal after it is the M2 refusal in the next plan.
  Date: 2026-11-23.

- Decision: A plan pays one more live read for each object it updates; the transition cost budgets
  in `cli/nagarectl/test/TransitionCostSpec.hs` were raised by exactly that read.
  Rationale: the plan reuses `prepareTakeover`'s read, as written. Answering it from the planning
  epoch would mean reading managed fields for every member in the grouped reads, which changes
  what every observation parses; that is a separate change if the cost is felt.
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
  Before this plan the reader was a `Maybe`, `Just` only under the opt-in. Since commit 224a34ff
  it is `ForeignFieldPlanning`: `ForeignFieldsUnread` (the execution adapter and the test builders
  such as `mkKubernetesAdapter`), `ForeignFieldsRefused` (every planning adapter without the
  opt-in) and `ForeignFieldsTakenOver` (the opt-in). `kubernetesPlanningAdapter` in
  `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesApplication.hs` chooses between the last
  two. `adapterPrepare` is called only while planning
  (`cli/nagarectl/src/Nagare/Inventory/Plan/Prepare.hs`). The refusal text and its marker are
  `foreignOwnerRefusal` and `foreignOwnerRefusalMarker` in `KubernetesConfiguration.hs`.
- `cli/nagarectl/app/Nagare/Cli/Inventory/Planning.hs`: `inventoryPlanRegistryWithTakeover :: Bool -> …`
  is the opt-in; `inventoryPlanRegistryWithNative` passes `False`, and `inventoryPlanRegistry` is
  that with no supplied native bytes. About 25 command modules under
  `cli/nagarectl/app/Nagare/Cli/Commands/` and `cli/nagarectl/app/Nagare/Cli/Data/` plan through
  these two with the opt-in off.
- `cli/nagarectl/app/Nagare/Cli/Bootstrap/Sequence.hs`, `planNextStage`: both `platform bootstrap
  plan` and `platform transition plan` (mode `ReleaseTransition`) plan here. Each call plans only
  the first stage that has work, in this order: local substrate, cloud perimeter, host image build
  and publication, host, kubeconfig, Cloudflare zone, then the platform scopes. The earlier stages
  plan through `inventoryPlanRegistry`. The platform stage builds its candidate with
  `buildPlatformCandidate` (`cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs`), which takes the
  inventory snapshot and reads the live cluster's Kubernetes version, and prepares it with
  `Inventory.prepareInventoryCandidateWithRetirementsPayload` through
  `inventoryPlanRegistryWithNative`; that function returns the review without writing it. Only the
  protected-route refresh uses `inventoryPlanRegistryWithTakeover True`.
- `cli/nagarectl/app/Nagare/Cli/Commands/Bootstrap.hs` (`runPlatformBootstrapPlan`),
  `Commands/Transition.hs` (`runPlatformTransitionPlan`) and `Inventory/Workflow.hs` (the
  `inventory plan` command) call the planners; the command constructors `PlatformBootstrapPlan`,
  `PlatformTransitionPlan` and `InventoryPlan` are in `cli/nagarectl/app/Nagare/Cli/Options.hs` and
  dispatched in `Dispatch.hs`.
- `cli/nagarectl/app/Nagare/Cli/Commands/Application.hs` threads `appOptions ^. #takeOverFields`
  into the registry for `app deploy`; its parser flag is in
  `cli/nagarectl/app/Nagare/Cli/Parser/Application.hs`. The platform and inventory parsers are
  `cli/nagarectl/app/Nagare/Cli/Parser/Platform.hs` and `Parser/Inventory.hs`.
- `cli/nagare-harness/src/Nagare/Harness/Release/Intranet.hs`, `converge`: plans each stage with
  `platform transition plan --out … --summary …`, applies it, and refuses on the first failure,
  printing the plan log's last five lines. Its options are `IntranetOptions` in the same module
  (constructed positionally there and in `Release/Publish.hs`); a stage's index entry is
  `StageEntry` in `cli/nagare-harness/src/Nagare/Harness/Release/RunIndex.hs`, also constructed in
  `Release/TransitionDrill.hs`. The candidate's own options and step order are in
  `Release/Candidate.hs`; `just release-candidate` passes its arguments through
  `scripts/release-candidate.sh`.
- A live object counts as drifted when its fields differ from the declaration, not only when its
  `nagare.dev/spec-digest` annotation does (`parseObserved` in
  `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`), so a hand patch of a
  declared field plans an `UpdateResource`.

Related work. `docs/plans/277-make-the-vm-resize-path-and-store-status-work-on-inventory-contexts.md`
fixes `inventory store status`, which reports `unsupported-schema` and omits `activeTransaction`
for every schema-2 head. On 2026-11-23 that made the harness's "no active transaction" check pass
while `tx-61b993f8…` was active. This plan relies on 277's first milestone and does not repeat it.

ADRs. [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md): a stopped
transaction is closed by per-operation proof; a plan-time refusal leaves nothing to close.
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md): an open
transition admits only its target payload; the M3 preflight refuses before the first stage is
planned, so it opens no transition marker. A refusal in a later stage's own plan (M2) leaves the
transition open at the stages already accepted, as any refused stage does. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md):
unit tests find defects, the local native run confirms.


## Plan of Work

M1. Add `--take-over-fields` to the `platform transition plan`, `platform bootstrap plan` and
`inventory plan` parsers. Thread the Bool to `planNextStage` and to the inventory plan command, and
use `inventoryPlanRegistryWithTakeover takeOver` wherever those commands now use
`inventoryPlanRegistryWithNative`. The route-refresh branch keeps `True`. Nothing in the adapter
changes: `prepareTakeover` already records the entries and the apply already honours them. Unit
tests assert that each parser sets the flag and that the registry receives it.

M2. When the flag is off, make planning fail for an `UpdateResource` whose live object has a
foreign manager (`foreignFieldManagers` non-empty, the executor's own rule). Reuse the live read
`prepareTakeover` does. Replace the adapter's `Maybe` reader with three states: no reader (today's
behaviour, kept for the execution adapter and the test builders), read and record (flag on), read
and refuse (flag off, used by the planning adapters). In the refuse state a non-empty `others`
becomes a `PrepareRefused` whose text starts with a fixed marker and names the object, each manager
and its fields, and the remedies, including the four commands that accept `--take-over-fields`.
Objects without foreign owners produce the same review bytes as today; a test pins this with an
existing review fixture. Tests go in `cli/nagarectl/test/InventoryKubernetesFieldTakeoverSpec.hs`.

M3. In `planNextStage`, when the mode is `ReleaseTransition` and a stage before the platform stage
has a candidate, run the preflight before planning that stage: build the platform candidate from
the current snapshot with `buildPlatformCandidate`, prepare it with the same registry the platform
stage uses, and discard the review. Stop with the M2 refusal text when a prepare error carries the
marker. Ignore every other outcome, including a failure to build the candidate. With
`--take-over-fields` the preflight finds nothing to refuse and the platform stage's own plan
records the takeover. `prepareInventoryCandidateWithRetirementsPayload` dies on a prepare error
today, so the preflight needs a variant that returns the errors. In local mode the platform stage
sets `KUBECONFIG` first; the preflight must do the same.

Start M3 with a bounded prototype: on a local context, call the preflight from a transition plan
whose pending stage is not the platform stage and confirm the platform candidate builds and
prepares. If it cannot be built before the earlier stage is accepted, stop and take that to the
operator; the fallback is to reword Purpose item 3 to "before the stage's first write".

The preflight renders against the cluster as it is before the host stage (`buildPlatformCandidate`
reads the live Kubernetes version), so its update targets can differ from the platform stage's
real plan. M2's refusal in that stage's own plan covers the difference.

In the harness, add a `takeOverFields` field to the candidate's options and to `IntranetOptions`,
parse `--take-over-fields`, append it to the `platform transition plan` arguments in `converge`,
and add an optional field to `StageEntry` that records it (optional so existing run indexes still
decode). `Release/Publish.hs` and `Release/TransitionDrill.hs` pass `False` and `Nothing`.

M4. Documentation as listed in Progress. Then `just mutation-check REV BASE` over the range (the
change touches an adapter), `just gate-fast`, `just land`, full gate green.


## Concrete Steps

From the repository root, on a local context (`just local-up`):

```bash
nagarectl platform bootstrap plan --out /tmp/ep280-1 && nagarectl inventory apply /tmp/ep280-1 --yes
kubectl -n nagare-system patch deploy shomei --type=merge -p '{"spec":{"replicas":2}}'
nagarectl platform bootstrap plan --out /tmp/ep280-2      # M2: refuses, names shomei and kubectl-patch
nagarectl platform bootstrap plan --out /tmp/ep280-3 --take-over-fields
jq -r '.operations[].summary' /tmp/ep280-3/review.json | grep 'takes over fields from kubectl-patch'
nagarectl inventory apply /tmp/ep280-3 --yes
kubectl -n nagare-system get deploy shomei -o json --show-managed-fields | jq -r '.metadata.managedFields[].manager' | sort -u
```

Repeat the first step until the plan has no operations if bootstrap needs more than one stage.
The patched field must be one Nagare declares, so the takeover removes the writer: `shomei`'s
manifest, `cluster/bootstrap/shomei/service.yaml`, sets `spec.replicas: 1`. A field Nagare does not
declare stays the writer's, and `confirmTakeoverSettled` stops the apply ambiguous, as today.

M3 has no native step of its own beyond the prototype: a local context has no host stage to
protect, and the first real confirmation is the next intranet candidate.


## Validation and Acceptance

M1 is accepted when the last command prints only `nagare-inventory` and status managers, and the
new parser and registry tests pass under `just gate-commit`. M2 is accepted when `/tmp/ep280-2`
refuses with the object, writer and fields named, an unpatched context's plan matches its fixture
byte for byte, and an adapter built without a reader prepares an update of a foreign-owned object
as it does today. M3 is accepted when the prototype passes; a unit test shows a transition whose
pending stage is the host stage refusing with the marker and writing no review when the platform
stage has a foreign-owned update target, and planning the host stage when the preflight fails for
any other reason; and a harness unit test (`cli/nagare-harness/test/ReleaseTransitionSpec.hs` or
`ReleaseCandidateSpec.hs`) shows `--take-over-fields` reaching `platform transition plan` and the
stage's index entry. M4 is accepted when the documents are committed, `just mutation-check` passes
and the landed revision's full gate is green.


## Idempotence and Recovery

Planning is read-only and can be repeated. A takeover review binds the object's UID and
resourceVersion: if the object changes after planning, the apply refuses before writing, and the
operator replans. A plan-time refusal writes nothing and opens no transaction; the preflight's
refusal also opens no transition. The preflight itself only reads and discards its review.


## Interfaces and Dependencies

No new libraries. `--take-over-fields` keeps the meaning it has on `app deploy`. The plan error is a
`PrepareRefused` whose text starts with a fixed marker the preflight matches; it names the resource
ID, the Kubernetes address, each manager and its fields. `app deploy` without `--save-plan` now
refuses at plan time on a foreign owner, where it refused at apply time before. Depends on
`docs/plans/277-make-the-vm-resize-path-and-store-status-work-on-inventory-contexts.md` M1 for a
truthful `inventory store status`.
