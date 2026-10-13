---
id: 190
slug: refuse-a-missing-access-key-before-admission-and-keep-observation-causes-in-plan-errors
title: "Refuse a missing access key before admission and keep observation causes in plan errors"
kind: exec-plan
created_at: 2026-10-13T13:24:48Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-13T13:24:48Z
---

# Refuse a missing access key before admission and keep observation causes in plan errors

This ExecPlan implements [IR-27](../improvement-requests/preflight-private-access-credentials.md).


## Purpose / Big Picture

An operator who grants site access (`nagarectl access grant … --save-plan`, then
`inventory apply`) without the private `NAGARE_EN_API_KEY` in their environment sees one of two
things today. At planning they get `observation-unavailable` with the generic message "required
resource observation is unavailable", which does not say a key is missing. At apply, a transaction
is admitted and an executor claim is taken, and only then does the access adapter refuse with
`adapter preflight refused: reviewed access requires private NAGARE_EN_API_KEY`. Authorization
fails closed both times, which is correct, but the operator has to guess, and the apply leaves a
transaction behind that must be resumed.

After this change:

- planning prints why each required access observation was unavailable, for example
  `observation-unavailable: required resource observation is unavailable: reviewed access requires private NAGARE_EN_API_KEY (access/…)`;
- `inventory apply` and `inventory resume` of a review containing access operations refuse before
  admission when the key is missing, leave the inventory unchanged, and say exactly what to set;
- `inventory status --json` carries the same reason in an access finding's `reason`.

Reasons from other executors stay redacted, as they are today. The key is never printed, stored in
a review, or journalled.


## Progress

- [x] M1 (2026-10-13): Plan errors and status findings carry the observation reason for access
  resources only; other executors keep the generic text. Plan errors print as
  `code: message (resources)` lines. Evidence: `test/InventoryAccessSpec.hs` "planning names why
  each access observation was unavailable (IR-27)" (missing key, port-forward failure, En refusal
  in `renderPlanErrors` output) and "status reports an access observation's reason; other
  providers stay redacted (IR-27)" (access `reason` in `DriftFinding` JSON; a Kubernetes route on
  the same inventory still reads `provider observation is unavailable`). The status case lives in
  the access spec because its fixture already composes a grant; the existing "private provider
  stderr" case in `test/InventoryStatusSpec.hs` is unchanged and passes.
- [x] M2 (2026-10-13): `accessKeyRefusal` gates `inventory apply` and `inventory resume` through
  `requireAccessKey` in `app/Nagare/Cli/Inventory/Workflow.hs`; recover and close keep the bare
  factory. Evidence: "an access review refuses before admission without the key; a refused
  preflight resumes once it is set (IR-27)" — refusal for `Nothing` and `Just ""`, none with a
  key or for a review without access operations; the refused preflight stops with the missing-key
  reason and `resumeTransaction` converges once the key is set; the sentinel key is absent from
  every file of the filesystem store and the written review, the rendered plan errors and the
  status JSON.
- [ ] M3: `docs/user/access.md` names the refusal and its fix. IR-27 is marked `completed`. Pass:
  `just gate-fast` is green, then `just land`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision (2026-10-13): Carry the reason in the existing `PlanError` message instead of adding a
  field. `PlanError` has 34 construction sites, and only the observation errors have a cause to
  report. Group unavailable access resources by reason, one `PlanError` per distinct reason, with
  message `required resource observation is unavailable: <reason>`.
- Decision (2026-10-13): Surface the reason only for resources whose executor is `AccessExecutor`.
  Commit `db22ce6b` deliberately redacts provider observation errors from public findings, and
  `test/InventoryStatusSpec.hs` pins that with an `ObservationUnavailable "private provider stderr"`
  case. Other adapters embed provider output in their reasons (for example
  `src/Nagare/Inventory/Adapters/Kubernetes.hs` "the StatefulSet's pods could not be read: …").
  Every reason the access observation path can return is a fixed string written in
  `src/Nagare/Inventory/AccessRuntime.hs`, with transport and owner errors already withheld, so no
  truncation or sanitising helper is needed. Supersedes the earlier `boundedReason` design.
- Decision (2026-10-13): The missing-key refusal wraps the registry factory for `inventory apply`
  and `inventory resume` only (`app/Nagare/Cli/Inventory/Workflow.hs` around lines 275 and 281),
  not `inventoryExecutionRegistry` itself. That factory is shared with recover, close and registry
  recovery (same file, around lines 334, 339 and 361), and
  `cli/nagarectl/src/Nagare/Inventory/README.md` forbids gating ahead of recovering an uncertain
  prerequisite. The check reads one environment variable and makes no network call. The access
  adapter's own preflight in the Driver stays the authoritative check.
- Decision (2026-10-13): The check is a pure function, `accessKeyRefusal`, taking the variable's
  value as an argument. The test suite cannot import `app/` modules and must not `setEnv` (tasty
  runs cases concurrently in one process).
- Decision (2026-10-13): No `--en-api-key` flag on `inventory apply` or `inventory resume`. The
  environment variable is the documented carrier, and the refusal names it. A flag would put the key
  in shell history.
- Decision (2026-10-13): JSON coverage is `inventory status --json`, the only JSON surface that
  reports observations. `inventory plan` and the access planning commands have no `--json`, and
  this plan does not add one.


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

Site access is an En relationship (a tuple such as `app:<host>#viewer@user:<id>`) that Nagare
writes through its inventory: a typed record of every resource it owns. Changes to it are planned
into a saved review, then applied as a transaction. All paths below are under `cli/nagarectl/`.

- **Key requirement.** `withContextEn` in `src/Nagare/Inventory/AccessRuntime.hs` (around line
  291) is the only reader of `NAGARE_EN_API_KEY`. Unset or empty, it returns
  `Left "reviewed access requires private NAGARE_EN_API_KEY"`. Otherwise it opens a one-call
  kubectl port-forward to the context's En Service. `accessRuntimeOps` (around line 160) uses it
  for both `accessInspect` (observation) and `accessWrite`. The other observation reasons are fixed
  strings in the same module: "en port-forward failed", "en port-forward did not become ready",
  "access transport failed; credentials and response body withheld", "access relationship query
  refused", "access owner observation failed", "access context guard refused", and the
  capability, schema and response-shape refusals.
- **Planning drops the reason.** The access adapter turns `Left reason` into
  `ObservationUnavailable reason` (`src/Nagare/Inventory/Access.hs`, around line 520).
  `ObservationUnavailable !Text` is defined in `src/Nagare/Inventory/Adapter.hs`.
  `src/Nagare/Inventory/Plan/Changes.hs` discards the text in three places: the `unavailable` list
  feeding `PlanError "observation-unavailable"` (lines 275 and 295), and the per-resource cases in
  `classifyDesired` (lines 784 and 825, message "resource observation is unavailable"). The
  resource's executor is available from the declarations (`resource ^. #executor`, as at line
  715). `src/Nagare/Inventory/Status.hs` (line 813) reports "provider observation is unavailable"
  the same way; `DriftFinding` already holds the executor. `src/Nagare/Inventory/Execute/Close.hs`
  (line 405) already keeps the reason. `PlanError` (`src/Nagare/Inventory/Plan/Types.hs`, around
  line 145) has `planErrorCode`, `planErrorMessage` and `planErrorResources`. It is printed by
  `prepareInventoryCandidateWithDeciderPayload` in `src/Nagare/Inventory/Command.hs` (lines
  502–506) with `dieText . showText . NE.toList`, which is Haskell `show` output.
- **Model harness.** `test/Nagare/Test/Model/Invariants.hs` (around line 256) and
  `test/Nagare/Test/Model/KnownDefects.hs` parse `PlanError {planErrorCode = …` text. They build
  that text with their own `T.pack . show` (`test/InventoryRecoveryModelSpec.hs` around line 860),
  not from CLI output, so `renderPlanErrors` does not affect them. Their refusals come from
  Kubernetes resources, whose message stays unchanged under this plan.
- **Admission happens before the adapter refuses.** `applyInventoryWithFactory` (lines 520–536)
  and `resumeInventoryWithFactoryTakeover` (lines 553–565) in `src/Nagare/Inventory/Command.hs`
  call the registry factory `registryFor store bundle` first, then `applyReviewed` or
  `resumeTransactionWithTakeover`. `applyReviewed` admits the review
  (`src/Nagare/Inventory/Execute/Admission.hs`: executor claim and a `Pending` journal entry).
  Only afterwards does the Driver (`src/Nagare/Inventory/Execute/Driver.hs`, lines 386–407) run
  the access adapter's `adapterPreflight`, which produces the `adapter preflight refused: …` text;
  on a retried operation it journals that refusal as `Failed (KnownNoEffect …)`. The factory is
  `inventoryExecutionRegistry` in `app/Nagare/Cli/Inventory/Execution.hs`. Its access-only branch
  (line 166) dies on a missing kubeconfig before admission. Its mixed branch first runs the
  platform release guard and Pulumi workspace preparation, checks the kubeconfig at line 529, and
  builds the access adapter at line 641. `accessReviewAdapter` is used only by this factory.
- **Planning and status entry points.** `access grant|revoke|team …|portal` go through
  `planRelationship` in `src/Nagare/Access/Reviewed.hs` (line 76). `withEnApiKey` there sets the
  variable from `--en-api-key` for the duration of the call. `inventory status` observes access
  through `ReviewedAccess.accessAdapter` (`app/Nagare/Cli/Commands/Inventory/Status.hs`, line 302).
- **Docs.** `docs/user/access.md` (line 316) says to set the key for planning, apply, recovery and
  `inventory status`, and that reviews never contain it. No test enforces that today.
- **Tests to extend.** `test/InventoryAccessSpec.hs` (tasty group "reviewed access"), which builds
  fake `AccessOps` and drives `applyReviewed` directly, and `test/InventoryStatusSpec.hs` (group
  "inventory status"). The test suite's `hs-source-dirs` is `test` plus the library; it cannot
  import `app/` modules, and no test drives the `Command.hs` entry points.

ADRs: [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) makes
reviewed, owned inventory transactions the only way to mutate. This plan keeps that and refuses
earlier. [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) defines site
access as a reviewed relationship per hostname.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): all
acceptance runs on fake adapters; no native run is needed.


## Plan of Work

### M1: Causes in plan errors and status

In `src/Nagare/Inventory/Plan/Changes.hs`, keep the reason paired with each unavailable resource.
For resources whose executor is `AccessExecutor`, group by reason and emit one
`PlanError "observation-unavailable"` per distinct reason, with the message
`required resource observation is unavailable: <reason>`. All other unavailable resources keep the
single generic error. In the two `classifyDesired` cases, append `: <reason>` only for access
resources. In `src/Nagare/Inventory/Status.hs`, put the reason into the finding's `reason` when
the finding's executor is `AccessExecutor`; keep "provider observation is unavailable" otherwise.

Add `renderPlanErrors :: NonEmpty PlanError -> Text` beside `PlanError`. It prints one line per
error, `<code>: <message> (<resource ids>)`, omitting the parentheses when there are no resources.
Use it in the three `showText . NE.toList` sites in `prepareInventoryCandidateWithDeciderPayload`.

Tests: in `test/InventoryAccessSpec.hs`, run `planChanges` against the access fixture with fake
`AccessOps` whose `accessInspect` returns each of the three reasons, and assert each reason
appears in the error message. In `test/InventoryStatusSpec.hs`, add an access finding case;
leave the existing Kubernetes "private provider stderr" case unchanged.

### M2: Refuse before admission

Export from `src/Nagare/Inventory/AccessRuntime.hs`:

```haskell
-- | The refusal for a review that has access operations while the private
-- key is unset or empty. Takes the variable's value so tests need no setEnv.
accessKeyRefusal :: Maybe String -> ReviewBundle -> Maybe Text
```

It returns
`reviewed access requires private NAGARE_EN_API_KEY; export it in this shell and rerun this command (the saved review stays valid)`
when any `reviewPlannedOperation` has `plannedExecutor == AccessExecutor` and the value is
`Nothing` or empty, and `Nothing` otherwise. Factor the emptiness test so `withContextEn` uses the
same predicate.

In `app/Nagare/Cli/Inventory/Workflow.hs`, wrap the factory passed at the apply call (line 275)
and the resume call (line 281):

```haskell
requireAccessKey registryFor store bundle = do
  key <- lookupEnv "NAGARE_EN_API_KEY"
  maybe (registryFor store bundle) dieT (accessKeyRefusal key bundle)
```

Because both commands call the factory before admitting or resuming, the refusal precedes the
executor claim and the journal, and it also precedes the mixed branch's platform guard and Pulumi
preparation. Recover, close and registry recovery keep the unwrapped factory.

Tests in `test/InventoryAccessSpec.hs`:

- `accessKeyRefusal`: an access review with `Nothing` and with `Just ""` refuses with the message
  above; with a key it returns `Nothing`; a review without access operations returns `Nothing`
  whatever the key.
- An access transaction admitted with `applyReviewed`, whose first attempt stopped because the
  fake `accessInspect` returned the missing-key reason, resumes with `resumeTransaction` and
  converges once the fake returns a fact.
- Sentinel: with a unique sentinel string as the key, run the fake-backed plan, apply and resume
  above, call `accessKeyRefusal (Just sentinel)`, render the plan errors and the status finding
  JSON, and assert the sentinel appears in none of them, nor in the published review bundle bytes
  or any store object or journal entry. The key has no channel into these: `withContextEn` is its
  only reader and passes it only to the request header.

### M3: Docs and request record

In `docs/user/access.md`, beside the existing key paragraph (line 316), quote the new refusal and
say that the saved review stays valid after setting the key. In
`docs/improvement-requests/preflight-private-access-credentials.md`, set `status: completed`,
`completedAt` and a `resolution` (`targetPlan` is already set). Add a
`docs/improvement-requests/log.md` entry.


## Concrete Steps

From `cli/nagarectl`:

```bash
cabal test nagarectl-test --test-options="-p '/reviewed access/ || /inventory status/'"
```

From the repository root:

```bash
just haskell-style-check && just gate-fast
just land
```


## Validation and Acceptance

| Situation | Observable result |
| --- | --- |
| `access grant … --save-plan` with no key | exits non-zero; stderr has an `observation-unavailable: …` line containing `reviewed access requires private NAGARE_EN_API_KEY` |
| Same, key set, port-forward fails | same code, reason `en port-forward failed` |
| Same, En refuses | same code, reason `access relationship query refused` |
| Planning with a Kubernetes resource unavailable | message unchanged, no provider text |
| `inventory apply REVIEW --yes` with no key | exits non-zero before admission with the `accessKeyRefusal` message; no claim or journal entry |
| `inventory recover` / `inventory close` with no key | not refused by the new check |
| `inventory resume TX --yes` after setting the key | converges |
| `inventory status --json` with no key | the access finding's `reason` is the missing-key reason |
| Sentinel key | absent from every output, review file and journal |


## Idempotence and Recovery

All changes are in planning output and in a refusal that happens before any write, so rerunning
any step is safe. The refusal does not invalidate a saved review.


## Interfaces and Dependencies

New: `Nagare.Inventory.AccessRuntime.accessKeyRefusal :: Maybe String -> ReviewBundle -> Maybe Text`
and `Nagare.Inventory.Plan.Types.renderPlanErrors :: NonEmpty PlanError -> Text`. `PlanError`'s
shape is unchanged. No dependency changes.
