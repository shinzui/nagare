---
id: 261
slug: scope-an-app-s-managed-env-and-secrets-to-the-workloads-that-reference-them
title: "Scope an app's managed env and secrets to the workloads that reference them"
kind: exec-plan
created_at: 2026-11-11T19:18:04Z
intention: "intention_01m760pfm7ej5sw9pagv1aftmc"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-11T19:18:04Z
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-12T15:37:27Z
      mode: "update"
      note: "Refreshed against v0.20.0: EP-259 landed, executable-only CLI check, no worker goldens in nagarectl, one-shot jobs out of scope, Kotei script pins, trailers"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-12T16:47:55Z
      mode: "implement"
      note: "M1 to M3 implemented; an Application's web service also inherits the Application's store"
---

# Scope an app's managed env and secrets to the workloads that reference them

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and
Outcomes & Retrospective current. Record implementation friction in the friction log as it
occurs (`agents/skills/exec-plan/FRICTION.md`).


## Purpose / Big Picture

Today every workload of an app receives the app's whole managed store: every key written with
`nagarectl env set` and `nagarectl secret set|sync` is injected into the web service and into
every task, whether or not the workload asked for it. An app therefore cannot keep a migration
credential away from its serving Pods, or a web token away from its worker.

After this change a web service, a worker or a task (including an Application's pre-deploy
hook) can declare `managedEnv = NoManagedEnv`. That workload then receives only what its own
configuration names: its inline variables, the Secret keys it references one by one, and its
database and broker bindings. A workload that says nothing behaves as before. The plan also
settles which store a worker inherits, and makes the guides say so.

It is visible in the live Pod spec. An opted-out container has no `envFrom` entry naming
`nagare-env-APP-runtime` or `nagare-secret-APP-runtime`, and its `env` list holds exactly the
names its configuration declares plus Nagare's own `NAGARE_*` variables.

This is IR-44
([docs/improvement-requests/scope-app-secrets-to-the-workloads-that-reference-them.md](../improvement-requests/scope-app-secrets-to-the-workloads-that-reference-them.md)),
raised for `mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application`.


## Progress

- [x] M1: `managedEnv` exists on the web service, worker and task types. An opted-out workload
  renders with no managed `envFrom`; a workload that does not opt out renders the same bytes
  and the same configuration JSON as before. Done 2026-11-12 in `a314e7a9`: `nagare-dsl-test`
  passes with the new "managed store opt-out (EP-261)" group, and no golden file changed.
- [x] M2: A reviewed Application deploy whose web service, worker and pre-deploy hook all opt
  out compiles to manifests with no managed `envFrom`, each naming only its own keys, with one
  runtime Secret dependency. An Application's worker and web service that do not opt out
  inherit the app's store. `nagarectl env` and `nagarectl secret` accept a standalone worker's
  configuration. Done 2026-11-12 in `a314e7a9`: `ManagedEnvScopeSpec` passes (3 cases), no
  golden file changed, and `just gate-fast` is green for `a314e7a9`. The built executable, on
  `cli/nagare-dsl/test/fixtures/worker/nagare/Config.hs`: before, `env list queue-consumer`
  died with "config emitted a 'Worker' but 'StaticSite or ServerSite' was expected"; after, it
  resolves the worker and reaches the store read.
- [x] M3: The user guides state, per workload kind, which store is inherited and how to opt
  out, and an ADR records the rule. Done 2026-11-12: the section "Which workloads receive the
  managed store" in `docs/user/env-and-secrets.md`, the field rows in `workers.md`,
  `scheduled-tasks.md`, `config-reference.md` and `deploying-apps.md`, and
  [ADR 38](../adr/0038-a-workload-inherits-its-app-s-managed-store-unless-it-opts-out.md).
- [x] M4: On a local context the fixture Applications pass, and the Kotei run is recorded as
  not possible here. Run 2026-11-12 on the disposable `transition` context of the v0.20.0
  rehearsal (k3d on Colima `nagare-mp23`) with the packaged `nagarectl 0.20.0 (a314e7a9)`;
  `just local-secret-scope-smoke` printed `secret-scope smoke: PASS` on two consecutive runs.
  - AC-1: "no container of scoped has an envFrom; each names only its declared keys".
  - AC-2: "each workload reads its own keys of the one runtime Secret and no other; the review
    names only application:secret-scoped-runtime/runtime-secret/secret". The hook exits
    non-zero if it sees any key but its own, and its Job completed.
  - AC-3: "plain, deployed by nagarectl 0.20.0 (f336bf6c), replans with no operations" (the
    v0.20.0 review had 5 operations, this build's review of the same tag 0).
  - AC-4: "secret set shared reaches shared-worker; shared-web and shared-worker name the
    Application's store".
  - AC-5: not run. Kotei's release image cannot be built here: it is an `aarch64-linux` Nix
    build over some twenty `shinzui/*` inputs, this machine has no ARM64 Linux builder with
    Kotei's cache, and Kotei's own build container is gone. No image was substituted. What was
    checked instead: a scratch copy of Kotei's `nagare/Config.hs` (at `db21e4bb`) with the
    opt-out passes `nagarectl app check` and `app render` at `a314e7a9`, all three roles carry
    `managedEnv: None`, and only `migrate` names `KOTEI_RELEASE_MAINTENANCE_DATABASE_URL`. The
    two-file diff is in IR-44's "What was delivered", for Kotei's plan 135 to run. IR-44 is
    `accepted`, with AC-5 open.


## Surprises & Discoveries

- An Application's web service had the same gap as its worker. `renderService` named the store
  after the service, so a service called otherwise than its Application (the `kizashi` fixture:
  app `kizashi`, service `kizashi-serve`) inherited a store no command could write. IR-44 and
  this plan had read "the web service inherits the app's store", which held only when the two
  names were equal, as in Kotei. Evidence: `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` at
  `70ef5f63`, `envFromField (serviceNameText (dep ^. #name))`. It changed the decision below.
- The hook Job is not ordered after the Secret directly. It is ordered after its CronJob, which
  carries the Secret dependency, so M2's test asserts the Job's ordering through the CronJob.
- `kubectl rollout restart` on a reviewed Deployment makes the next reviewed apply refuse
  ("fields managed by another writer: kubectl-rollout"). The smoke replaces the Pod instead.
  The one occurrence was cleared by the runbook's close and `--take-over-fields`, after
  removing the smoke's own annotation.
- Friction: [FRIC-15](../friction-log/15-mori-registry-refuses-to-start-on-a-projection-catalog-mismatch.md)
  and [FRIC-16](../friction-log/16-the-artifact-transport-reports-success-after-failing-under-macos-bash-3-2.md).


## Decision Log

- Decision: Deliver the request as a per-workload opt-out of the inherited store, with keys
  reached by explicit Secret reference, and not as several named Secrets per app.
  Rationale: The request allows either. The opt-out reuses what the reviewed deploy already
  has: every referenced Secret must be an accepted resource passed with
  `--env-secret-resource`, so each key a workload reads is visible in the review. Named Secrets
  per app would add a second channel identity to `nagarectl secret`, to channel scopes, to
  retirement and to delegation, for the same result in the acceptance case. It also follows
  ADR 36, where a Pod holds no Kubernetes token unless it names an account.
  Date: 2026-11-11

- Decision: The field is a two-constructor type, `ManagedEnv = InheritManagedEnv |
  NoManagedEnv`, on `Deployment`, `Worker` and `Task`. Its JSON key `managedEnv` is written
  only for `NoManagedEnv` and an absent key loads as `InheritManagedEnv`.
  Rationale: A named type reads better at the call site than a `Bool` and leaves room for a
  later constructor. Writing the key only when set keeps every existing app's configuration
  digest, and so its saved review, unchanged (IR-44 AC-3).
  Date: 2026-11-11

- Decision: An Application's worker inherits the app's store, `nagare-env-APP-runtime` and
  `nagare-secret-APP-runtime`. A standalone worker keeps the store named after itself.
  Rationale: IR-44 AC-4 asks for one of two fixes. `Nagare.Dsl.Application` and
  `docs/user/workers.md` already say a worker shares the app's store; only the renderer
  disagrees, naming a store after the worker that no command can write for an Application.
  Consequence the operator should know: an existing Application's worker that received no
  managed values (its store could not be written) will, on its next deploy, receive every key
  of the app's store. The change is one `envFrom` name in the saved review, and such a worker
  can set `NoManagedEnv`. This is the one place the default changes, and it is why AC-3's
  "unchanged" check uses an app without workers or compares only web and task manifests.
  Date: 2026-11-11

- Decision: Out of scope: the Application's own `env` field, server sites, one-shot jobs, and
  checking at plan time that a referenced key exists in the accepted Secret.
  Rationale: `Application.env` is declared shared and still flows to every workload; an app
  that wants per-role values puts them on each workload, as Kotei does. Server sites
  (`Nagare.Dsl.Server.Render`) are a different type and were not requested, and the request
  excludes Preview-scoped env; the preview overlay (`Nagare.Env.PreviewOverlay`) is applied
  only to server and static sites, so it cannot put the store back on an opted-out workload.
  A one-shot job (`Nagare.Dsl.Job`) is a fourth kind that is never part of an Application; it
  keeps its `envFrom` of a store named after the job, and M3's guide says so. A missing key
  fails the Pod at start, as an explicit reference to any Secret does today; a plan-time key
  check would be a new guarantee.
  Date: 2026-11-11, one-shot jobs added 2026-11-12

- Decision: The store commands' acceptance of a standalone worker is proved by running the
  built executable, not by a unit test.
  Rationale: `configIdentityOrDie` lives in the executable's sources (`cli/nagarectl/app`),
  which neither `nagarectl-test` nor `just gate-fast` compiles. Moving it into the library for
  one test is more change than the fix.
  Date: 2026-11-12

- Decision: Inside an Application every workload inherits the Application's store: the web
  service as well as the workers. `renderServiceIn` takes the store's app name as
  `renderWorkerIn` does, and `renderServiceObjects` passes the rollout's app.
  Rationale: The guide can then state one rule, and the alternative documents a store nobody
  can write. A standalone web service is unchanged, because its rollout app is the service
  itself. Consequence: an Application's web service whose name differs from the Application's
  changes its `envFrom` name on the next deploy, exactly as its workers do.
  Date: 2026-11-12

- Decision: M4's fixture asserts its hook with `--hook-no-data-effects`, not `--hook-affects`,
  and reads a web container's names without Knative's `PORT` and `K_*`.
  Rationale: The fixture's hook changes no managed data, and Knative adds those variables to
  every web container.
  Date: 2026-11-12


## Outcomes & Retrospective

A web service, worker or task can now refuse its app's managed store with
`managedEnv = NoManagedEnv` and receive only the keys it names, and inside an Application every
workload inherits the Application's store; IR-44 AC-1 to AC-4 pass on a local context
(`just local-secret-scope-smoke`) and the rule is ADR 38. What remains is AC-5, the run of
Kotei's own image through its release script, which belongs to Kotei's plan 135 and starts from
the diff in IR-44; and the release notes of the next release, which must say that a
`Deployment`, `Worker` or `Task` record literal needs `managedEnv` and that an Application's
worker, and a web service named differently from its Application, change the store they
inherit. Friction: FRIC-15 (mori would not start; accepted, mori's own guard) and FRIC-16 (the
artifact transport under macOS bash 3.2; accepted, the cause was a hand-made `PATH`). Nothing
further moves to an ADR.


## Context and Orientation

Paths are repository-relative. Terms used below:

A *workload* is one of the three things an app runs: a web service (type `Deployment` in
`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`, rendered as a Knative Service), a worker (type
`Worker` in `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`, rendered as a Kubernetes Deployment), or
a task (type `Task` in `cli/nagare-dsl/src/Nagare/Dsl/Task.hs`, rendered as a CronJob). An
*Application* (`cli/nagare-dsl/src/Nagare/Dsl/Application.hs`) bundles an optional web service,
workers and tasks under one name. The tasks listed on the Application itself are its
*pre-deploy hooks*: each release runs them once as a Job, before the serving workloads are
promoted. A web service, worker or task can also be deployed on its own, which this plan calls
*standalone*.

The *managed store* of an app is two Kubernetes objects per scope, written only by
`nagarectl env` and `nagarectl secret`: the ConfigMap `nagare-env-APP-SCOPE` and the Secret
`nagare-secret-APP-SCOPE`. The names come from `managedConfigMapName` and `managedSecretName`
in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`. This plan concerns the Runtime scope only.
*Inheriting* the store means the container carries a Kubernetes `envFrom` block naming both
objects with `optional: true`, which injects every key they hold.

An *explicit Secret reference* is an `EnvSecretRef secretName` entry in a workload's `env`
map. It renders as one `env` entry with `valueFrom.secretKeyRef`, whose key is the variable's
own name (`envEntryValue` in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`). A *reviewed deploy*
compiles the configuration into the resource inventory, saves a review and applies it
(`nagarectl app deploy --save-plan DIR`, then `nagarectl inventory apply DIR`). It refuses a
reference unless the named Secret is an accepted inventory resource passed with
`--env-secret-resource RESOURCE-ID` (`secretDependency` in
`cli/nagarectl/src/Nagare/Inventory/Application/Environment.hs`).

A *local context* is a k3d cluster with loopback substitutes for every cloud service
([docs/user/local-development.md](../user/local-development.md)); the GCP guardrail steps aside
there by design.

What the code does today, checked at commit `47a97795` (v0.20.0 plus documentation):

- The web service always inherits. `containerValue` in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`
  appends `envFromField` with the service's name.
- A task inherits when it names an app (`app = Just name`). `envFromPairs` in
  `cli/nagare-dsl/src/Nagare/Dsl/Task/Render.hs` calls `managedEnvFromPairs` from
  `cli/nagare-dsl/src/Nagare/Dsl/Batch/Render.hs`. A pre-deploy hook is rendered through the
  same path: `renderTaskObjects` in `cli/nagarectl/src/Nagare/App/Deploy.hs`, then
  `compileApplicationHooks` in `cli/nagarectl/src/Nagare/Inventory/Application/Tasks.hs` copies
  the CronJob's Pod template into the Job.
- A worker inherits a store named after the worker. `containerValue` in
  `cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs` calls `envFromField (nameText w)`. For a
  worker `kotei-worker` inside the Application `kotei` that is `nagare-secret-kotei-worker-runtime`.
- `nagarectl env` and `nagarectl secret` resolve the app through `resolveAppOrDie` in
  `cli/nagarectl/app/Nagare/Cli/Application/Config.hs`. It dies unless the positional APP equals
  the configuration's name, and `configIdentityOrDie` beside it loads only a Deployment, an
  Application or a site. So the worker-named store cannot be written for an Application, and
  from reading the code a standalone `Worker` configuration is not accepted either; M2 confirms
  the second with the built executable before changing it. This module is part of the
  executable, which the test suite and `just gate-fast` do not compile.
- A database or app-database binding reaches a workload as explicit `env` entries
  (`cli/nagarectl/src/Nagare/Inventory/Application/Environment.hs`), never through `envFrom`,
  so an opted-out workload keeps its bindings. Since v0.20.0 a `Task` carries `appDatabases`
  too, and a pre-deploy hook named in an app-owned database's `owners` receives the owner
  credential that way.
- A one-shot job (`cli/nagare-dsl/src/Nagare/Dsl/Job/Render.hs`) also inherits a store, named
  after the job. This plan leaves it alone (Decision Log).
- An Application's own `env` map is merged into every workload by `flowEnv` in
  `cli/nagarectl/src/Nagare/App/Deploy.hs`. This plan leaves it alone (Decision Log).
- A task also receives Nagare's own variables `NAGARE_TASK_NAME`, `NAGARE_NAMESPACE`,
  `NAGARE_APP` and `NAGARE_RUN_ID` (`cli/nagarectl/src/Nagare/Task/Resolve.hs`). They stay, so
  IR-44 AC-1's "exactly its declared keys" is read as the declared names plus `NAGARE_*`.

The request's findings were checked against this code and hold. Three points refine it. The
worker gap is wider than stated (a standalone worker's store looks unwritable too). AC-3 and
AC-4 pull against each other for an Application that has workers; the Decision Log resolves
it. And Kotei's `scripts/kotei-nagare-release.sh` accepts only a CLI reporting version
`0.18.0` at one of two pinned revisions, and its `nagare/Config.hs` builds `Task` without the
`appDatabases` field v0.20.0 added, so AC-5 needs more on Kotei's side than the opt-out.

Relevant ADRs:
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) is the
typed inventory the reviewed deploy compiles into; a workload's Secret references become
ordered dependencies there, and this plan adds none of a new kind.
[ADR 36](../adr/0036-application-pods-hold-no-kubernetes-api-token-unless-they-name-an-account.md)
is the precedent for a per-workload field on all three types that removes something a Pod
holds without asking; the field added here follows its shape in the types, the JSON and the
loaders (search for `serviceAccount`). No ADR covers the managed store's inheritance; M3 adds
one.

Related work, landed in v0.20.0:
[EP-259](259-let-tasks-and-pre-deploy-hooks-bind-an-app-database-under-a-named-url-variable.md)
(IR-43 AC-5) gives a pre-deploy hook the database owner credential through a binding. With
this plan as well, Kotei's hook can get the owner credential from the binding and nothing from
the store. Kotei has not adopted the binding yet; AC-5 here does not require it.


## Plan of Work

### M1: the opt-out in the configuration library

Scope: `cli/nagare-dsl`. At the end the three types carry the field, the JSON carries it, and
the three renderers honour it.

In `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` add and export:

```haskell
-- | Whether a workload inherits its app's Runtime-scoped managed ConfigMap and Secret.
data ManagedEnv = InheritManagedEnv | NoManagedEnv
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)
```

Add `managedEnv :: !ManagedEnv` to `Deployment` (same file), to `Worker`
(`cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`) and to `Task` (`cli/nagare-dsl/src/Nagare/Dsl/Task.hs`).
The presets `webService` (`cli/nagare-dsl/src/Nagare/Dsl/Presets.hs`), `webWorker` and
`scheduledTask` set `InheritManagedEnv`. Every other place that builds one of these records
with full record syntax needs the new field; find them with
`git grep -n 'serviceAccount = ' -- cli docs`, since that field sits on the same three records.

In `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`, the three JSON encoders (deployment, worker,
task) append `"managedEnv": "None"` only for `NoManagedEnv`, the way `logicalKey` is appended
only when present. In `cli/nagare-dsl/src/Nagare/Dsl/Load/Deployment.hs`, `Load/Worker.hs` and
`Load/Task.hs`, read the key with `.:?`; absent or `"Inherit"` is `InheritManagedEnv`, `"None"`
is `NoManagedEnv`, anything else is a `MarshalError "managedEnv"`.

Renderers: in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` and
`cli/nagare-dsl/src/Nagare/Dsl/Task/Render.hs` emit the `envFrom` block only for
`InheritManagedEnv`. In `cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs` do the same, and let
the caller name the store: add `renderWorkerIn :: Text -> Worker -> Text -> [ByteString]`
taking the store's app name, and define `renderWorker w = renderWorkerIn (nameText w) w` so a
standalone worker is unchanged. Update the module comments that say the block is "always
present".

Tests, in `cli/nagare-dsl/test/Spec.hs`, `cli/nagare-dsl/test/WorkerSpec.hs` and
`cli/nagare-dsl/test/ApplicationSpec.hs` next to the existing `serviceAccount` render and
round-trip cases: for each of the three kinds, an opted-out value renders
no `envFrom` key and still renders its `env` entries, including a `secretKeyRef`; the JSON of a
default value has no `managedEnv` key; JSON without the key loads as `InheritManagedEnv`;
`"None"` round-trips; an unknown value is refused. Existing golden output must pass untouched.

### M2: the reviewed deploy and the CLI

Scope: `cli/nagarectl`. At the end an Application's worker shares the app's store, an
all-opted-out Application compiles as IR-44 AC-1 and AC-2 describe, and the store commands
accept a worker configuration.

In `cli/nagarectl/src/Nagare/App/Deploy.hs`, `renderWorkerObjects` calls
`renderWorkerIn (env ^. #appName)`. For a standalone worker the rollout's `appName` is the
worker's own name (`compileStandaloneWorkerWithDependencies` in
`cli/nagarectl/src/Nagare/Inventory/Application/Worker.hs` requires it), so only an
Application's worker changes. Check any other caller of `renderWorker` with
`git grep -n renderWorker -- cli`.

No compile rule changes for the opt-out itself: the hook Job is copied from the CronJob's Pod
template, and `secretDependency` already requires an accepted resource for each referenced
Secret. Prove it with tests rather than new code.

In `cli/nagarectl/app/Nagare/Cli/Application/Config.hs`, let `configIdentityOrDie` fall
through to `Load.loadWorker` before the site loaders, so `nagarectl secret set WORKER -f
Config.hs` writes a standalone worker's store. Correct the error text in `resolveAppOrDie`,
which says "the config's name is what the Service references". Evidence is from the built
executable (`cabal build exe:nagarectl --project-dir=cli/nagarectl`): against
`cli/nagare-dsl/test/fixtures/worker/nagare/Config.hs`, a store command that needs no cluster
write (`nagarectl env list WORKER -f ...` on a local context, or its dry run) is refused with
an unexpected-kind error before the change and resolves the worker's name after it.

Tests, beside the existing Application compile cases (`cli/nagarectl/test/Nagare/Test/Application.hs`,
`cli/nagarectl/test/InventoryApplicationSpec.hs`, `cli/nagarectl/test/AppDeploySpec.hs`): build
an Application `scoped` with a web service, one worker and one pre-deploy hook, all
`NoManagedEnv`, referencing different subsets of four keys of `nagare-secret-scoped-runtime`.
Compile it with that one Secret as the only `scopeEnvSecrets` entry and assert, from the
compiled native manifests of the Knative Service, the Deployment, the CronJob and the hook Job:
no `envFrom` key; the `env` names equal the declared names (plus `NAGARE_*` on the task and
Job); each object depends on the Secret's resource ID. Add one case where the worker does not
opt out and its `envFrom` names `nagare-env-scoped-runtime` and `nagare-secret-scoped-runtime`.
No golden file should change: the worker golden files are in `cli/nagare-dsl/test/golden` and
render standalone workers, and `cli/nagarectl/test/golden` holds one CronJob. An existing
assertion on an Application worker's store name, if one turns up, is updated to the app's
name.

### M3: guides and the decision record

In `docs/user/env-and-secrets.md` add a section "Which workloads receive the managed store"
stating: a web service and a task that names an app inherit the app's store; an Application's
worker inherits the app's store; a standalone worker inherits the store named after itself,
written with `nagarectl secret set WORKER -f Config.hs`; `managedEnv = NoManagedEnv` removes
the inheritance; an opted-out workload reaches a Secret key by `EnvSecretRef` to
`nagare-secret-APP-runtime` and the deploy passes that Secret with `--env-secret-resource`;
values set with `nagarectl env set` are not reachable by an opted-out workload because there is
no per-key ConfigMap reference; the Application's own `env` still reaches every workload; a
one-shot job inherits the store named after the job and has no opt-out.
Include a short three-role example (web, worker, migration hook). Fix the sentence in
`docs/user/workers.md` under the field table and the `env` row ("managed `envFrom` is always
wired"), the matching "an `envFrom` block always" sentence in `docs/user/deploying-apps.md`
and the inherited-env rows of `docs/user/scheduled-tasks.md`, and add the `managedEnv` field to the tables in `docs/user/workers.md`,
`docs/user/scheduled-tasks.md` and `docs/user/config-reference.md`. Note in
`docs/user/deploying-apps.md`, where `--env-secret-resource` is described, that the app's own
runtime Secret is passed the same way when a workload references it.

Write the ADR in `docs/adr/`, following the frontmatter and numbering of the files already
there (take the next number after the highest present when you write it): workloads inherit
the app's Runtime store unless they opt out, an Application's worker shares the app's store,
and named Secrets per app were rejected for now.

### M4: confirm on a local context

Add `scripts/local-secret-scope-smoke.sh` and a `local-secret-scope-smoke context` recipe in
`justfile`, modelled on `scripts/local-app-database-smoke.sh` (same context checks, same
`app image-plan` publication helper, same `apply` helper). Register the script and the recipe
in `scripts/audit-managed-commands.py` in the three places `local-app-database-smoke` appears.
On a bootstrapped local context it:

1. Publishes one image whose default entrypoint serves HTTP and which has a shell, and writes
   four keys to the app's store with a reviewed `nagarectl secret sync scoped`.
2. Plans and applies the M2 Application `scoped` with the one runtime Secret resource and a
   `--hook-affects` assertion for its hook. Asserts from each live Pod
   (`kubectl get pod -o json`) that no container has an `envFrom` naming
   `nagare-env-scoped-runtime` or `nagare-secret-scoped-runtime`, that each container's `env`
   names are its declared set plus `NAGARE_*`, that each workload reads its keys (the hook's
   log, and `kubectl exec ... env` in the worker), and that the saved review lists the one
   Secret dependency. This is AC-1 and AC-2.
3. Deploys a web-only app with no opt-out before and after switching `NAGARECTL` between the
   v0.20.0 package (`nix build "git+file://$PWD?ref=v0.20.0#nagarectl"`) and this build, and
   asserts the second plan has no operations. This is AC-3.
4. Writes a key with `nagarectl secret set` for a second Application whose worker does not opt
   out, redeploys, and asserts the worker's environment holds it. This is AC-4's command check.

Then the acceptance case, AC-5. Kotei's checkout is found with
`mori registry show shinzui/kotei --full`. Work on a scratch copy of its `nagare/Config.hs`
and `scripts/kotei-nagare-release.sh` and change nothing in Kotei's repository: add
`managedEnv = NoManagedEnv` to the service, the worker and the `migrate` task, add
`Task.appDatabases = []` and any other field the records gained since v0.18.0, and replace the
script's version and revision check (it accepts only `0.18.0` at two revisions) with this
build's version and revision. Run the script's `plan-image`,
`apply-image`, `plan-app` and `apply-app` on the local context with Kotei's release image and
its four keys in `nagare-secret-kotei-runtime`. Accept when the hook Job completes, the web
service and worker become ready, and neither serving Pod spec names
`KOTEI_RELEASE_MAINTENANCE_DATABASE_URL`. If Kotei's image cannot be built for the local
context, record that in Progress and stop at the fixture evidence; do not substitute an image
and call it AC-5. Hand the two-file diff to
`mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application` in the
improvement request's closing note.

Finally set `status` in
`docs/improvement-requests/scope-app-secrets-to-the-workloads-that-reference-them.md`, noting
under AC-3 and AC-4 what was delivered differently from the text, in the form other completed
requests in that directory use.


## Concrete Steps

All from the repository root.

```bash
cabal test nagare-dsl-test --project-dir=cli/nagare-dsl --test-show-details=direct
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p Application' --test-show-details=direct
cabal build exe:nagarectl --project-dir=cli/nagarectl
just haskell-style-check
just gate-fast
```

Per Haskell commit run `just haskell-style-check` then `just gate-fast`; land with
`just land HEAD` (rules in `CLAUDE.md`). The fast gate does not compile
`cli/nagarectl/app`, so build the executable before committing M2's change there. For M4:

```bash
just local-secret-scope-smoke <local-context>
```

Expected last line:

```text
secret-scope smoke: PASS
```

Commits follow Conventional Commits and carry the plan trailer. The `Intention:` trailer is not
used in this repository (`CLAUDE.md`).

```text
ExecPlan: docs/plans/261-scope-an-app-s-managed-env-and-secrets-to-the-workloads-that-reference-them.md
```


## Validation and Acceptance

M1 is accepted when the new library tests pass and `git status` shows no changed golden file.
M2 is accepted when the new compile tests pass, no golden file changed, the built executable
resolves a standalone worker's configuration, and `just gate-fast` is green. M3 is accepted when a reader of
`docs/user/env-and-secrets.md` alone can say which store each workload kind inherits and how
to opt out. M4 is accepted when the smoke prints `PASS` and the Kotei run meets the three
conditions above, or records why it could not run.

The early check of the one uncertain interface is M2's compile test of the hook Job: it shows
that the opt-out set on a `Task` survives rendering, tag resolution and the CronJob-to-Job
copy before any cluster is involved.


## Idempotence and Recovery

Every code step is additive and can be repeated. The smoke script reuses its publications on a
rerun and works on a disposable local context; tear the context down and repeat after a fix.
A failed pre-deploy hook leaves nothing promoted, which is the designed behaviour; correct the
cause and plan a new release. If a guard, check or script refuses, stop and report to the
operator. Nothing in this plan touches a cloud context.


## Interfaces and Dependencies

New public surface, all in `cli/nagare-dsl`: `Nagare.Dsl.Types.ManagedEnv (InheritManagedEnv,
NoManagedEnv)`; the field `managedEnv` on `Nagare.Dsl.Types.Deployment`,
`Nagare.Dsl.Worker.Worker` and `Nagare.Dsl.Task.Task`; the optional JSON key `managedEnv` with
values `"Inherit"` and `"None"`; `Nagare.Dsl.Worker.Render.renderWorkerIn` and `Nagare.Dsl.Render.renderServiceIn`. A `Config.hs`
that builds these records with full record syntax must add the field when it moves to this
build, as it did for `serviceAccount`; say so in the release notes.

No dependency on another plan. Kotei's
adoption of the field and of the qualified Nagare revision belongs to
`mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application`.
