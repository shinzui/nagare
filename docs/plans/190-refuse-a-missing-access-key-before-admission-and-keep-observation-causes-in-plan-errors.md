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

- planning prints why each required observation was unavailable, for example
  `observation-unavailable: reviewed access requires private NAGARE_EN_API_KEY (access/…)`;
- `inventory apply` and `inventory resume` of a review containing access operations refuse before
  admission when the key is missing, leave the inventory unchanged, and say exactly what to set;
- `inventory status --json` carries the same reason in a drift finding's detail.

The key is never printed, stored in a review, or journalled.


## Progress

- [ ] M1: Plan errors and status findings carry the adapter's observation reason, bounded to one
  line. Plan errors print as readable lines instead of Haskell `show`. Pass: new cases in
  `InventoryAccessSpec` and `InventoryStatusSpec` show three distinct causes (missing key,
  port-forward failure, En refusal) in the plan error text and in `inventory status --json`.
- [ ] M2: Apply and resume of a review with access operations refuse before admission when
  `NAGARE_EN_API_KEY` is empty. Pass: a test shows the store head, journal and claims unchanged
  after the refusal. Resuming an admitted access transaction after the key is supplied converges.
  A sentinel key appears in no stdout, stderr, review file or journal entry.
- [ ] M3: `docs/user/access.md` names the refusal and its fix. IR-27 is marked `completed`. Pass:
  `just gate-fast` is green, then `just land`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision (2026-10-13): Carry the reason in the existing `PlanError` message instead of adding a
  field. `PlanError` has 34 construction sites, and only the observation errors have a cause to
  report. Group unavailable resources by reason, one `PlanError` per distinct reason, with message
  `required resource observation is unavailable: <reason>`.
- Decision (2026-10-13): The missing-key refusal is a check that an environment variable is
  present, placed in the registry factory beside the existing kubeconfig refusal. This is not
  "a live preflight in factory construction", which `cli/nagarectl/src/Nagare/Inventory/README.md`
  forbids. No network call moves, and the adapter's own preflight in the Driver stays as the
  authoritative check.
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
  291) reads `NAGARE_EN_API_KEY` from the environment. Without it, it returns
  `Left "reviewed access requires private NAGARE_EN_API_KEY"`. It opens a one-call kubectl
  port-forward to the context's En Service. `accessRuntimeOps` (around line 160) uses it for both
  `accessInspect` (observation) and `accessWrite`. Other safe, distinct reasons come from the same
  module: "en port-forward failed", "en port-forward did not become ready", "access transport
  failed; credentials and response body withheld", "access relationship query refused".
- **Planning drops the reason.** The adapter turns `Left reason` into
  `ObservationUnavailable reason` (`src/Nagare/Inventory/Adapters/Access.hs`, around line 520).
  `ObservationUnavailable !Text` is defined in `src/Nagare/Inventory/Adapter.hs`.
  `src/Nagare/Inventory/Plan/Changes.hs` discards the text in three places: the `unavailable` list
  feeding `PlanError "observation-unavailable"` (around lines 275 and 295), and the per-resource
  cases around lines 784 and 825. `src/Nagare/Inventory/Status.hs` (around line 813) reports
  "provider observation is unavailable" the same way. `src/Nagare/Inventory/Close.hs` already
  keeps the reason. `PlanError` (`src/Nagare/Inventory/Plan/Types.hs`, around line 145) has
  `planErrorCode`, `planErrorMessage` and `planErrorResources`. It is printed by
  `prepareInventoryCandidateWithDeciderPayload` in `src/Nagare/Inventory/Command.hs` with
  `dieText . showText . NE.toList`, which is Haskell `show` output.
- **Admission happens before the adapter refuses.** `applyInventoryWithFactory` and
  `resumeInventoryWithFactoryTakeover` (`src/Nagare/Inventory/Command.hs`) build the adapter
  registry with `registryFor store bundle` first, then call `applyReviewed` or
  `resumeTransactionWithTakeover`. `applyReviewed` admits the review
  (`src/Nagare/Inventory/Execute/Admission.hs`: executor claim and a `Pending` journal entry).
  Only afterwards does the Driver (`src/Nagare/Inventory/Execute/Driver.hs`, around lines 386–407)
  run the access adapter's `adapterPreflight`, which produces the
  `adapter preflight refused: …` text. The registry factory is `inventoryExecutionRegistry` in
  `app/Nagare/Cli/Inventory/Execution.hs`. Its access-only branch (around line 166) already dies on
  a missing kubeconfig before admission. The mixed branch (around line 641) constructs the access
  adapter for every review.
- **Planning entry points.** `access grant|revoke|team …|portal` go through `planRelationship` in
  `app/Nagare/Cli/Access/Reviewed.hs`. `withEnApiKey` there sets the variable from
  `--en-api-key` for the duration of the call.
- **Docs.** `docs/user/access.md` (around line 316) says to set the key for planning, apply,
  recovery and `inventory status`, and that reviews never contain it. No test enforces that today.
- **Tests to extend.** `test/InventoryAccessSpec.hs`, which builds fake `AccessOps` throughout, and
  `test/InventoryStatusSpec.hs` (around line 68, which asserts the current generic text).

ADRs: [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) makes
reviewed, owned inventory transactions the only way to mutate. This plan keeps that and refuses
earlier. [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) defines site
access as a reviewed relationship per hostname.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): all
acceptance runs on fake adapters; no native run is needed.


## Plan of Work

### M1: Causes in plan errors and status

In `src/Nagare/Inventory/Plan/Changes.hs`, keep the reason paired with each unavailable resource
and group by reason. Emit one `PlanError "observation-unavailable"` per distinct reason, with the
message `required resource observation is unavailable: <reason>`. Apply the same change to the two
per-resource cases. Add one small function, `boundedReason :: Text -> Text`, that keeps the first
line, replaces control characters and truncates to 240 characters. Use it wherever an observation
reason reaches output, so an adapter that ever passes provider stderr cannot flood or break the
output. In `src/Nagare/Inventory/Status.hs`, put the bounded reason into the finding's detail.

Add `renderPlanErrors :: NonEmpty PlanError -> Text` beside `PlanError`. It prints one line per
error, `<code>: <message> (<resource ids>)`. Use it in the three `showText . NE.toList` sites in
`prepareInventoryCandidateWithDeciderPayload`. Update the `InventoryStatusSpec` expectation.

### M2: Refuse before admission

Export `requireAccessKey :: IO (Either Text ())` from `src/Nagare/Inventory/AccessRuntime.hs`. It
uses the same emptiness test as `withContextEn` and returns the message
`reviewed access requires private NAGARE_EN_API_KEY; export it in this shell and rerun this command (the saved review stays valid)`.
`withContextEn` uses it too, so there is one test. In `inventoryExecutionRegistry`, call it in the
access-only branch beside the kubeconfig check. In the mixed branch, call it only when the review
has an operation whose `plannedExecutor` is `AccessExecutor`. Because both `applyInventoryWithFactory`
and resume build the registry before admitting or resuming, this covers apply and resume.

Tests in `test/InventoryAccessSpec.hs`:
- With the variable unset, an apply through the factory refuses. The store head, journal and
  executor claims are byte-equal before and after.
- An admitted access transaction that stopped on the adapter refusal (today's behaviour, built
  through the fake) resumes and converges once the variable is set.
- Sentinel: set the key to a unique string and run plan, apply, a lost-response resume and status
  through fakes. Assert the string appears in no captured stdout or stderr, no file under the
  review directory, and no journal or store entry.

### M3: Docs and request record

In `docs/user/access.md`, beside the existing key paragraph, quote the new refusal and say that
the saved review stays valid after setting the key. In
`docs/improvement-requests/preflight-private-access-credentials.md`, set `status: completed`,
`completedAt`, `targetPlan` and a `resolution`. Add a `log.md` entry.


## Concrete Steps

From `cli/nagarectl`:

```bash
cabal test nagarectl-test --test-options="-p '/InventoryAccess/ || /InventoryStatus/'"
```

From the repository root:

```bash
just haskell-style-check && just gate-fast
just land
```


## Validation and Acceptance

| Situation | Observable result |
| --- | --- |
| `access grant … --save-plan` with no key | exits non-zero; stderr has `observation-unavailable: required resource observation is unavailable: reviewed access requires private NAGARE_EN_API_KEY (…)` |
| Same, key set, port-forward fails | same code, reason `en port-forward failed` |
| Same, En refuses | same code, reason `access relationship query refused` |
| `inventory apply REVIEW --yes` with no key | exits non-zero before admission with the `requireAccessKey` message; store unchanged |
| `inventory resume TX --yes` after setting the key | converges |
| `inventory status --json` with no key | the access finding's detail is the bounded reason |
| Sentinel key | absent from every output, review file and journal |


## Idempotence and Recovery

All changes are in planning output and in a refusal that happens before any write, so rerunning
any step is safe. The refusal does not invalidate a saved review.


## Interfaces and Dependencies

New: `Nagare.Inventory.AccessRuntime.requireAccessKey :: IO (Either Text ())` and
`Nagare.Inventory.Plan.Types.renderPlanErrors :: NonEmpty PlanError -> Text`. `PlanError`'s shape
is unchanged. No dependency changes.
