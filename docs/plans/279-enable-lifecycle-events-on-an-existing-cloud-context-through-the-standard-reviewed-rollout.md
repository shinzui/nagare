---
id: 279
slug: enable-lifecycle-events-on-an-existing-cloud-context-through-the-standard-reviewed-rollout
title: "Enable lifecycle events on an existing cloud context through the standard reviewed rollout"
kind: exec-plan
created_at: 2026-11-23T05:25:32Z
intention: "intention_01m83dvjkkem1v4sqj0z9rfr0p"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-23T05:25:32Z
---

# Enable lifecycle events on an existing cloud context through the standard reviewed rollout

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).



## Purpose / Big Picture

A Nagare context can publish lifecycle events (`app.deployed`, `change.applied`, backup events and
the rest listed in `docs/user/lifecycle-events.md`) and serve them through the protected admin API
at `GET /v1/events`. A small program, the lifecycle worker `nagare-events`, writes them into a
feed stored beside the context's inventory. On a local context this works. On a cloud (GCP)
context it did not work with any released package. The Labs installation
(`mori://tan/tan-ng-labs`) got its portal to read its own deployment event on Nagare v0.27.0 only
with a patched `nagarectl`, a corrected Pulumi payload, two hand-made IAM changes and a dedicated
worker image. Its plan, `mori://tan/tan-ng-labs/plans/24-show-nagare-change-events-in-the-portal-admin`,
records each failure. This plan answers improvement request IR-52
(`docs/improvement-requests/enable-lifecycle-events-through-the-standard-cloud-rollout.md`).

After this plan, an operator of an existing GCP context runs the ordinary reviewed sequence with
the released CLI and images and nothing else. The sequence is: `context create --force
--enable-lifecycle-events --save-plan`, `context apply`, the cloud stage of `platform bootstrap`,
the worker key from `docs/runbooks/lifecycle-worker-key.md`, then the platform stage. They then
deploy an application and read its `app.deployed` event from `GET /v1/events` and
`GET /v1/events/{id}` using the admin API credentials the context already has. No IAM change
by hand, no custom image and no patched CLI.

Four defects stand between today and that outcome. Each one is a deliverable below:

1. The context review drops En tenant declarations.
2. The cloud plan grants the feed at the wrong prefix for a bare `inventory` root, and gives the
   admin API no feed access.
3. The worker sends a billing project it has no permission to use.
4. The worker reads the inventory through a transport that cannot list. Once that is fixed, its
   start-up takes longer than the platform apply allows.


## Progress

- [ ] M1 (AC-1): a lifecycle opt-in review of a context that declares En tenants saves, applies
  and leaves every field but the lifecycle settings byte-identical; an unknown key is still
  refused.
- [ ] M2 (AC-2, offline): the Pulumi worker grants and the worker's runtime use the same feed
  prefix for bare and nested inventory roots. The admin API reader gets object reads on the
  feed's head, segments and indexes only. The worker's GCS requests carry no billing project.
- [ ] M3 (AC-3, offline): the worker opens the inventory through its own read-only transport,
  which lists and batch-reads. Its probes answer from process start, and readiness waits for
  activation. Activation plus the first receipt cycle read the journal once and each converged
  review and schedule revision at most once, on a fixture with at least 12,478 journal entries
  and several historical backup schedules.
- [ ] Release: a Nagare release that carries M1 to M3 is published through the `nagare-release`
  skill and the intranet runs it.
- [ ] M4 (AC-2 native, AC-3 native, AC-4): on a disposable cloud context, with the released CLI
  and images and delivery off, the standard reviewed workflow enables the feed. The native IAM
  allow and deny matrix passes. The worker becomes ready within the 180 s rollout deadline,
  cold and after a restart. An `app.deployed` event read through the protected list and
  detail endpoints matches by ID, transaction, resource and release. F154 is closed in
  `docs/audits/mp23-findings.md`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: the worker sends no billing project (`userProject`). Its Storage requests use
  `quotaProjectFor`, which returns nothing for a service account of the context's own project.
  The worker gets no project-level role.
  Rationale: Labs granted a custom project role with `serviceusage.services.use`. The delegated
  deployer hit the same 403 and was fixed this way in `064479d4`
  (`docs/audits/ep248-cloud-iam-check-2026-11-11.md`). The worker component's design binds it
  only on buckets, never on the project. A per-project custom role would also clash between two
  contexts in one project, and may not have propagated when its binding is created in the same
  update (EP-248 finding 1).
  Date: 2026-11-23

- Decision: the admin API reads the feed through a new conditional binding with the predefined
  `roles/storage.objectViewer`. It is declared inside `NagareLifecycleWorker` and names only
  `<feed>/head.json`, `<feed>/segments/`, `<feed>/index/` and `<feed>/ids/`. The reader's
  existing custom role and binding stay as they are.
  Rationale: an existing stack without lifecycle events must preview unchanged, so the reader's
  own condition is not edited. A predefined role avoids the custom-role propagation failure when
  both are enabled in one update. Cloud Storage checks `storage.objects.list` against the bucket,
  and no condition here names the bucket, so the role's list permission never applies (EP-248 D6).
  Date: 2026-11-23

- Decision: the worker's Deployment gets no `startupProbe`. The probe listener starts before
  activation, liveness answers at once, and readiness reports "activating" until activation
  finishes.
  Rationale: Labs added a 15-minute `startupProbe` only because nothing listened during
  activation. Once the listener starts first, that step is unnecessary. The platform apply still
  waits 180 s for the Deployment (`statelessReadiness` in
  `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`). A longer probe would only
  hide a slow start behind an ambiguous apply, so start-up must fit 180 s instead.
  Date: 2026-11-23

- Decision: two Labs patch parts are out of scope: the `NAGARE_LIFECYCLE_ONLY` planner in
  `Bootstrap/Sequence.hs` and the `NAGARE_LIFECYCLE_WORKER_IMAGE` override.
  Rationale: the lifecycle-only planner existed because Labs' platform stage also carried
  unrelated pending backup and stamp updates that the operator did not want to apply yet. The
  standard rollout applies the whole reviewed platform stage. The released `nagare-admin-api`
  image already ships `nagare-events` (`nix/release-images.nix`), so once M3 is released no
  worker image override is needed.
  Date: 2026-11-23

- Decision: the 12,478-entry start-up proof is offline (request counts on a generated fixture).
  The disposable cloud context confirms the timing natively on its own, smaller journal. If
  the operator agrees, the large-history native confirmation is Labs' restart when it moves to
  the release, recorded in Labs' own plan.
  Rationale: ADR 25 says defects are found by interpreters and native runs only confirm. A
  disposable context cannot honestly hold 12,478 entries, and copying another context's journal
  would break its binding. Labs is the context where the slow start was measured.
  Date: 2026-11-23


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

Terms used below:

- A context is one named target installation. Its settings are a flat file of
  `export VAR=value` lines in `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`. A
  cloud context's inventory lives in GCS, at `NAGARE_INVENTORY_STORE_URL` or the default
  `gs://<project>-nagare-pulumi-state/nagare/<context>/inventory`. Contexts created by the
  inventory bootstrap (Labs, the EP-248 drill contexts) use a bare root,
  `gs://<project>-<context>-state/inventory`.
- The inventory is Nagare's recorded state: `head.json`, an append-only journal of one object
  per event (`journal/<20-digit sequence>.json`), content-addressed reviews (`reviews/`), scope
  revisions (`scopes/`) and native object bytes.
- The feed is the lifecycle event store beside the inventory. `feedLocation` in
  `cli/nagare-core/src/Nagare/Events/Store.hs` derives it: a location ending in `/inventory`
  becomes `<parent>/lifecycle/v1`, and any other gets `-lifecycle/v1` appended. Its objects are
  `head.json`, `segments/<digest>.json`, `index/<digest>.json` and `ids/<digest>.json` (keys near
  line 141 of that file). The worker's private state also lives there: `receipts/head.json`,
  `delivery/sender.json` and `worker-transition.json`.
- A context review is the saved, digest-bound proposal that `nagarectl context create --force
  ... --save-plan DIR` writes and `nagarectl context apply DIR --yes` applies
  (`cli/nagarectl/src/Nagare/Context/Review.hs`).
- The cloud stage is the reviewed Pulumi update that `platform bootstrap` plans. Its config is
  derived from the context by `seedKeysFor` in `cli/nagarectl/src/Nagare/Init.hs`. Its program is
  `infra/pulumi/index.ts`, and the resources it may contain are listed per feature in
  `infra/pulumi/resource-catalog.json`.
- A billing project is the `userProject` query parameter on a Storage request. Sending it requires
  `serviceusage.services.use` on that project.

Defect 1, the context review. `renderTargetEnv` (`cli/nagarectl/src/Nagare/Init.hs`, near line
324) renders a `TargetProfile` as context lines. It omits `NAGARE_EN_TENANTS` and each
`NAGARE_EN_TENANT_<NAME>_SCHEMA`, although the profile carries them as `enTenants`
(`cli/nagarectl/src/Nagare/Target.hs`, near line 415). `cli/nagarectl/src/Nagare/Context/Review.hs`
uses that renderer twice. Near line 191 it builds the allowlist of fields a context file may hold,
so a context with tenants is refused with "context review refuses unrecognized profile fields;
keep credentials outside the profile". Near line 110 it renders the replacement, which would drop
the tenants. `Nagare.Target.EnTenants.renderEnTenantDeclarations` already renders them, and
`renderContextShellEnv` in `Target.hs` (line 553) uses it. The same renderer also writes context
files in `cli/nagarectl/app/Nagare/Cli/Runtime/Context.hs` line 132, so that path loses tenants too.

Defect 2, the cloud grants. `infra/pulumi/src/components/NagareLifecycleWorker.ts` creates the
worker account `nagare-events` and binds it only on buckets: object and bucket viewer on the
inventory prefix, `roles/storage.objectUser` on the feed prefix, and viewer on the backup
bucket. Its `lifecyclePrefix` maps `"inventory"` to `inventory-lifecycle/v1`. The program
receives a bare `inventory` from `adminApiInventoryKeys` in `Init.hs` for
`gs://bucket/inventory`. The runtime's `feedLocation("gs://bucket/inventory")` is
`gs://bucket/lifecycle/v1`, so the grants and the runtime disagree.
`infra/pulumi/src/components/NagareAdminApiReader.ts` gives the API's reader `storage.objects.get`
on `format.json`, `head.json`, `versions/latest.json` and `scopes/` only. The API opens the feed
through the same reader (`cli/nagare-api-server/app/Main.hs` line 88), so every event request
answered `503 store_unavailable`. Tests: `infra/pulumi/test/lifecycleWorkerResources.test.ts`,
`adminApiReaderResources.test.ts` and `resourceProgramParity.test.ts`. They run with `npm test`
in `infra/pulumi`.

Defect 3, the billing project. The worker executable is
`cli/nagare-api-server/app/Events.hs`. `openStores` builds its feed transport with
`gogolObjectOpsWithEnv writer project (feedLocation url)`
(`cli/nagare-core/src/Nagare/Inventory/Store/Gogol.hs` line 137), which always passes
`Just project` as the billing project. `quotaProjectFor` in the same file (line 118) already
returns `Nothing` for an account ending in `@<project>.iam.gserviceaccount.com`. The worker's key
is such an account.

Defect 4, the inventory transport and start-up. `openStores` opens the inventory with
`openServiceStore` (`cli/nagare-core/src/Nagare/Inventory/Store/Service.hs`). That is the admin
API's session, whose `readOnlyObjectOps` refuses `listObjects` and `getObjects` without a
request, so `readJournalPrefix` (`cli/nagare-core/src/Nagare/Inventory/Store.hs` line 856)
fails. `main` runs `activate` before the probe server starts, so Kubernetes saw no listener and
restarted the pod. `activate` (`cli/nagare-api-server/src/Nagare/Api/Events/Worker.hs` line 120)
resolves the backup schedules through `currentSchedules config access Nothing`. It caches
nothing, so the first receipt cycle resolves them all again. Resolution is `loadBackupSchedules`
(`cli/nagare-core/src/Nagare/Events/BackupSources.hs`). For each schedule it calls
`convergedScheduleRevisionsIn` (`cli/nagare-core/src/Nagare/Inventory/ScheduleHistory.hs`), which
loads the full published review bundle of every converged review (`loadPublishedReview`). The
cost is therefore schedules × converged reviews bundle reads. `convergedScheduleRevisions` there
is also used by `cli/nagarectl/app/Nagare/Cli/Data/ScheduledReceipts.hs`, so it guards which
backup receipts are accepted. Existing tests are in `cli/nagarectl/test/EventsBackupSpec.hs`
and `cli/nagarectl/test/Nagare/Test/Backup/Scheduled.hs`. The worker's tests are in
`cli/nagare-api-server/test/Nagare/Api/Server/Test/Worker.hs`, over a memory world (`newWorld`,
`commit`, `configOf`). The cloud Deployment template is
`cluster/bootstrap/lifecycle-events/lifecycle-events-cloud.yaml.tmpl`.

The Labs patch is evidence for these fixes: `mori://tan/tan-ng-labs`, project-relative
`operator/intranet/nagare-lifecycle-v0.27.0.patch` (file-level URI pending). Use it as a guide,
not as code to copy. One difference matters. Its `convergedScheduleRevisionsFromReviews` reads a
schedule's scope revision only from `scopes/`. The current code first takes it from the review
bundle's embedded scopes and falls back to `scopes/` only when it is missing there. M3 must
keep the accepted expectations identical, so that difference is pinned by a test.

ADRs. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md):
defects are found by interpreters and fakes, and native runs only confirm. So each defect gets
an offline test first, and M4 confirms.
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md):
operator keys never enter this repository or Pulumi state, so the worker key stays a
`gcloud iam service-accounts keys create` step in the operator's repository.
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md): every
cloud path asserts the active context's project. M4 runs only against the disposable context's
project.
[ADR 39](../adr/0039-lifecycle-sources-are-committed-by-the-converged-release.md): the journal
sequence is every lifecycle consumer's checkpoint. Activation must not move an existing feed's
journal checkpoint. [ADR 33](../adr/0033-lifecycle-delivery-separates-destination-state-from-transport-adapters.md)
covers delivery, which stays off throughout. The open audit finding F154
(`docs/audits/mp23-findings.md`) says the worker's cloud denials have never been checked natively.
M4 closes it.


## Plan of Work

### M1: the context review keeps En tenants

In `cli/nagarectl/src/Nagare/Init.hs`, make `renderTargetEnv` append
`renderEnTenantDeclarations (tp ^. #enTenants)`, quoted with `shellQuote` as the other optional
lines are. That one change fixes the allowlist, the replacement and the context-file writer. An
unknown key is still refused, because the allowlist remains exactly the rendered keys plus
`transportKeys`. Check the compatibility comparison in `Review.hs` (near line 200), which
decides which profile fields a review may change. A tenant change must stay refused there, or
be compared as an identity, as it is today.

Add tests to `cli/nagarectl/test/ContextReviewSpec.hs`. The fixture context declares
`NAGARE_EN_TENANTS=mori,team-a` with both schema variables, and every other field populated.
Save a review that turns on `--enable-lifecycle-events` and apply it. Parse the written context
before and after. They must differ only in `NAGARE_LIFECYCLE_EVENTS_ENABLED` (`0` to `1`), and
the tenant lines must be preserved. A second fixture adds `NAGARE_UNKNOWN=1` and must still be
refused with the existing message. Extend the `renderTargetEnv` round-trip test in
`cli/nagarectl/test/Nagare/Test/Init.hs` with a profile that has tenants.

### M2: one feed prefix, the API's feed read, no billing project

In `infra/pulumi/src/components/NagareLifecycleWorker.ts`, make `lifecyclePrefix` return
`lifecycle/v1` for a trimmed prefix equal to `inventory`. Keep the `/inventory` suffix rule and
the `-lifecycle/v1` fallback. Add parity cases to `lifecycleWorkerResources.test.ts` (`inventory`,
`inventory/`, `nagare/intranet/inventory`, `nagare/intranet/store`). Add the same table as a
`feedLocation` test on `gs://b/<prefix>` in the nagarectl suite, next to the existing feed tests
in `cli/nagarectl/test/EventsDeliverySpec.hs` or a target-feed test. Each test names the other in
a comment.

Add the admin API's feed read. `NagareLifecycleWorkerArgs` gains an optional
`adminApiReaderEmail`, which `infra/pulumi/index.ts` passes as `adminApiReader?.email`. When it
is present, the component declares `${name}-api-feed`, a `gcp.storage.BucketIAMMember` on the
state bucket. Its role is `roles/storage.objectViewer` and its member is the reader. Its
condition is `lifecycleFeedReadCondition(bucket, inventoryPrefix)`: exactly `resource.name ==
"<root>/head.json"` or `startsWith` `<root>/segments/`, `<root>/index/` and `<root>/ids/`, where
`<root>` is the feed's object root. It never names the bucket and never names `receipts/`,
`delivery/` or `worker-transition.json`. Add the member to the `lifecycleWorkerEnabled` section of
`infra/pulumi/resource-catalog.json` at layer 20, and make `resourceProgramParity.test.ts` pass.
If the parity test cannot express "only with the admin API", follow how that test models
optional members and record the choice here. Test the exact condition string for a bare and a
nested root.

In `cli/nagare-core/src/Nagare/Inventory/Store/Gogol.hs`, give `gogolObjectOpsWithEnv` an
explicit `Maybe Text` billing project. `newGogolObjectOps` keeps passing `Just project`, so its
behaviour is unchanged. Update the existing caller in `cli/nagarectl/test/InventoryGogolSpec.hs`.
In `Service.hs`, make `serviceWriterEnv` also return the key's `client_email`. In `Events.hs`,
pass `quotaProjectFor project email` to every worker transport. The backup reader already passes
`Nothing`.

Prove it offline. Point a worker-shaped transport at a loopback fake GCS that answers 403 to
any request with a `userProject` query, as `InventoryServiceStoreSpec.hs` line 219 does. Then
show that a feed write and an inventory listing succeed for a key whose email is in the fixture
project.

### M3: the worker's own read-only inventory, probes first, one pass over history

In `Events.hs` `openStores`, cloud branch, keep `openServiceStore` only for its ownership check.
Call its `freshHead` once and die on failure, so the bucket must still belong to the
configured project number. Then open the inventory with `openObjectStoreReadOnly` over
`gogolObjectOpsWithEnv writer project quota url`, wrapped so that `putObject` is refused before
any request (as `readOnlyFeedOps` does for the feed). The client name is `events-worker` and the
cache is `--cache-dir`. The worker then lists and batch-reads with its own account's grants and
can never write the inventory.

In `main`, start the probe server first and `link` it. Install the signal handlers next, then
run activation. An `MVar` marks activation done. `/health/live` answers 200 from the start.
`/health/ready` answers 503 `activating the lifecycle worker` until the `MVar` is set, then
reports `ready status` as today. A failed activation still exits non-zero with its reason.

In `Worker.hs`, `activate` takes the `WorkerStatus` and resolves schedules with
`currentSchedules config access (Just status)`. The first receipt cycle then reuses them while
the head has not moved. Read the collector head first: when collection is already active,
activation must not resolve schedules at all. Confirm in `Nagare.Events.Receipts` that
`activateCollection` ignores its schedules argument when collection is enabled. If it does not,
keep the call and rely on the shared cache.

In `ScheduleHistory.hs`, add `convergedReviewSet`. It reads each converged review's published
bundle once, in journal order, and keeps for each the desired revisions and the embedded scope
bytes. Add `convergedScheduleRevisionsFrom`, which resolves one schedule against that set. It
reads each distinct scope revision once, taking the bundle's bytes first and `scopes/` second,
as today. Then it reads and checks that revision's CronJob native bytes. Make
`convergedScheduleRevisionsIn` and `convergedScheduleRevisions` wrappers over the two, so
`ScheduledReceipts.hs` keeps its behaviour. In `BackupSources.hs`, build the set once per
`loadBackupSchedules` and pass it to every schedule. Before removing the per-schedule loop, add
an equivalence test to `cli/nagarectl/test/EventsBackupSpec.hs`. It uses a fixture with three
schedules, each changed across several converged reviews, plus one review that did not converge,
and checks that the old and new paths give identical expectations in identical order.

Add a start-up test to `cli/nagare-api-server/test/Nagare/Api/Server/Test/Worker.hs`. The world
holds at least 12,478 journal entries from many `commit`s, at least 50 converged reviews and at
least three backup schedules, each with at least three historical revisions. Wrap the
inventory's object operations in a counter (the store's `StoreCounters` or a local wrapper).
Run `activate` and then one `receiptCycle`, and assert:

- the journal is batch-read once;
- each `reviews/<digest>` object is read at most once;
- each `scopes/<digest>` object is read at most once;
- no inventory write happens.

Then restart: build a new config over the same world, activate again and assert that:

- the feed head's journal checkpoint and generation are unchanged;
- no schedule is resolved;
- a subsequent `commit world [deploy "a"]` and two source cycles publish exactly one
  `app.deployed` with one stable ID.

### Release

Cut a release with M1 to M3 through the `nagare-release` skill (`.claude/skills/nagare-release`).
It must prove the three things `CLAUDE.md` requires after v0.5.0: a green full gate, the EP-172
upgrade rehearsal on a disposable local context, and the intranet upgrading and passing the
deploy-and-login check. Nothing in this plan changes the intranet's lifecycle setting.

### M4: the native rollout on a disposable cloud context

Create a disposable cloud context, `ep279`, in the operator's project, using the released CLI
and the standard inventory bootstrap, which gives it the bare root
`gs://<project>-ep279-state/inventory`. Enable the admin API as the bootstrap guide does. Then
run the rollout an operator would run: the reviewed context opt-in with delivery off, the
cloud stage (inspect the preview, which must show the seven worker resources plus
`nagare-lifecycle-worker-api-feed` and no other change), the worker key, and the platform stage.
Time the worker from pod creation to Ready. Delete the pod, time it again, and check that the
feed head's journal checkpoint is unchanged.

Run the IAM matrix with only the worker key, then with only the admin API reader key. Each runs
in its own `CLOUDSDK_CONFIG` under `env -i`, modelled on
`docs/audits/ep248-cloud-iam-check-2026-11-11/scripts/ep248-iam.sh`.

The worker key must be allowed to:

- read `inventory/head.json`;
- read a journal event;
- write and overwrite `lifecycle/v1/<probe>`;
- read a backup object.

The worker key must be refused when it tries to:

- write `inventory/<probe>`;
- write or delete in the backup bucket;
- write beside both prefixes;
- send any request that carries `--billing-project <project>`. This shows the worker holds no
  project role and needs none.

The reader key must be allowed to read `lifecycle/v1/head.json` and a `segments/`, an `index/`
and an `ids/` object. It must be refused when it tries to:

- list the bucket;
- write anything;
- read `lifecycle/v1/receipts/head.json`;
- read `inventory/journal/`.

Deploy an application. Read `GET /v1/events?type=app.deployed` and `GET /v1/events/{id}` with a
`client_credentials` token from the context's existing admin API client
(`docs/user/access.md`, "Sign in native clients and services"). Compare `id`, transaction,
resource and release with the deployment's transaction in `nagarectl inventory history`.

Record the evidence in `docs/audits/ep279-cloud-lifecycle-rollout-<date>.md`, with scripts and
transcripts beside it as EP-248's audit has them. Close F154 there. Update
`docs/runbooks/lifecycle-worker-key.md` to describe the API's feed grant and state that the
worker needs no project role. Then tear the context down. Ask the operator once for the bounded
command sequence before any cloud mutation (CLAUDE.md, "Host and cloud mutation rules").


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/nagare`, in the dev
shell.

Per Haskell commit, then per landing:

```bash
just gate-commit
just gate-fast
just land <rev>
```

Pulumi tests after M2's TypeScript changes:

```bash
cd infra/pulumi && npm test
```

Expected tail: every test file runs and the command exits 0. A failing assertion prints its
message, for example `the feed prefix differs from the inventory's sibling`.

M3 changes `ScheduleHistory.hs`, which decides which backup receipts are accepted. Run the
mutation check before landing it. If it selects no record, there is nothing to run:

```bash
just mutation-check <rev> <base>
```

M4's rollout, after the operator's go-ahead, with the released `nagarectl` and `ep279` active:

```bash
nagarectl context create ep279 --force --enable-lifecycle-events --save-plan ./ep279-ctx
nagarectl context apply ./ep279-ctx --yes
nagarectl platform bootstrap plan --out ./ep279-cloud      # the cloud stage: worker account and grants
nagarectl platform bootstrap apply ./ep279-cloud --yes
# worker key: docs/runbooks/lifecycle-worker-key.md, "Enable", in the operator repository
nagarectl platform bootstrap plan --out ./ep279-platform   # the platform stage: the worker Deployment
nagarectl platform bootstrap apply ./ep279-platform --yes
kubectl -n nagare-system get pod -l app.kubernetes.io/name=nagare-events -w
```

Each `plan` plans the next pending stage. Read every review's operations before its apply: the
cloud review holds only the worker's resources and its API feed grant, and the platform review
holds the `platform:lifecycle-events` scope.

Expected event read (values elided):

```text
$ curl -s -H "Authorization: Bearer $TOKEN" "https://api.<base>/v1/events?type=app.deployed"
{"events":[{"id":"evt-…","type":"app.deployed","data":{"transaction":"tx-…","resource":…,"release":…}}],…}
```


## Validation and Acceptance

AC-1 passes when the two new `ContextReviewSpec` tests pass. One checks that only
`NAGARE_LIFECYCLE_EVENTS_ENABLED` changed and the tenant lines survived; the other checks the
unknown-key refusal. Before the fix the first test fails with "context review refuses
unrecognized profile fields".

AC-2 passes offline when these pass: the TypeScript and Haskell prefix tables, the exact
condition strings for `nagare-lifecycle-worker-feed` and `nagare-lifecycle-worker-api-feed`, the
catalog parity test, and the loopback test that 403s any `userProject`. It passes natively when
every row of M4's two IAM matrices matches its expectation.

AC-3 passes offline when the start-up test's counts hold on the 12,478-entry world, the restart
assertions hold, and the schedule-history equivalence test passes. Natively, the worker on `ep279`
must become Ready within 180 s both cold and after a pod deletion. The platform apply's
Deployment wait must complete without "did not prove availability".

AC-4 passes when the platform stage converges with the released CLI and images and no
override, and the event read through the protected list and detail endpoints matches the
deployment's transaction by ID, transaction, resource and release.


## Idempotence and Recovery

M1 to M3 are code and tests. Re-running gates is safe. The schedule-history change keeps the
old functions as wrappers until the equivalence test passes, so it can be reverted alone.

In M4, `context create --force --save-plan` and `platform bootstrap plan` only write review
directories. Re-running them replaces a review. An apply that stops is resumed or closed with
`nagarectl inventory resume` or `nagarectl inventory close`, per ADR 26. Never hand-edit IAM on
the context. If a guard refuses, stop and report it; do not work around it. Turning the
worker off (`--disable-lifecycle-events`) removes the Deployment and keeps all lifecycle state.
Deleting the worker key with `gcloud iam service-accounts keys delete` revokes it. The disposable
context is torn down at the end. Its state bucket, service accounts and keys go with it.


## Interfaces and Dependencies

- `Nagare.Init.renderTargetEnv :: TargetProfile -> Text` also renders the En tenant lines.
- `Nagare.Inventory.Store.Gogol.gogolObjectOpsWithEnv :: StorageEnv -> Text -> Maybe Text -> Text
  -> Either Text ObjectOps`: the environment, the project, the billing project, then the URL.
- `Nagare.Inventory.Store.Service.serviceWriterEnv :: FilePath -> HTTP.ManagerSettings -> IO
  (Either StoreError (StorageEnv, Text))`: the environment and the key's `client_email`.
- `Nagare.Api.Events.Worker.activate :: WorkerConfig -> WorkerStatus -> IO (Either Text ())`.
- `Nagare.Inventory.ScheduleHistory.convergedReviewSet` and `convergedScheduleRevisionsFrom`,
  with the existing `convergedScheduleRevisions` and `convergedScheduleRevisionsIn` as wrappers.
- Pulumi: `NagareLifecycleWorkerArgs.adminApiReaderEmail?: pulumi.Input<string>`,
  `lifecycleFeedReadCondition(bucket, inventoryPrefix)`, and the catalog member
  `nagare-lifecycle-worker-api-feed`.
- The gogol Storage SDK (`mori://brendanhay/gogol/repos/gogol`) for `userProject`, and Cloud
  Storage's IAM condition semantics on `resource.name`.

M4 depends on the release. Nothing depends on this plan's interfaces outside this repository.
Labs keeps its patched image until it moves to the release.
