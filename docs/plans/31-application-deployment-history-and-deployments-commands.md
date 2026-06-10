---
id: 31
slug: application-deployment-history-and-deployments-commands
title: "Application deployment history and deployments commands"
kind: exec-plan
created_at: 2026-06-10T00:33:39Z
intention: "intention_01ktqexbzyeb2bfka9q38w3gmx"
master_plan: "docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md"
---

# Application deployment history and deployments commands

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is a child of the MasterPlan at
`docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md`. It is self-contained. It *prefers*
to reuse two helpers (`streamServiceLogs`, `appIdentityOrDie`) introduced by the sibling plan
`docs/plans/30-nagarectl-app-lifecycle-commands.md`; if that plan has not landed, this plan introduces
the same helpers itself (their signatures are stated below so either plan can own them). Everything
else here is independent.


## Purpose / Big Picture

Static sites in Nagare already keep a release history: every successful `nagarectl site deploy` records
a `StaticRelease` in a per-site Kubernetes ConfigMap, and `nagarectl site releases` prints it
(newest-first, the live one marked) — implemented in `cli/nagarectl/src/Nagare/Static/Release.hs`.
Applications get nothing of the sort. `nagarectl deploy` builds, pushes, applies, waits, and prints a
URL, but leaves no Nagare-level record of *what was deployed when*. An operator who wants to know "what
image is live, and what was live before it" must read Knative revisions by hand.

This plan gives applications the same deployment history and the commands to read it:

```text
nagarectl deploy            # now also records a deployment on success
nagarectl deployments list NAME
nagarectl deployments logs NAME [DEPLOYMENT_ID]
```

After this plan, every successful `nagarectl deploy` appends a record (deployment id = the image tag,
the image, the resolved URL, an optional `--source` provenance string, and a UTC timestamp) to a
per-app ConfigMap. `nagarectl deployments list notes` prints that history as an aligned table with the
live deployment marked. `nagarectl deployments logs notes` streams the live deployment's container
logs, and `nagarectl deployments logs notes 20260610-120000` streams the logs for the Knative revision
that a specific past deployment id produced (so you can read the logs of a deployment that has since
been superseded, as long as its revision's pods still exist).

You can see it working: deploy an app twice with different tags, then `nagarectl deployments list NAME`
shows two rows with the newer one starred, and `nagarectl deployments logs NAME` prints logs from the
running revision.


## Progress

- [ ] M1: per-app deployment history store (reuse/generalize `Nagare.Static.Release`) with pure-layer unit tests.
- [ ] M2: `runDeploy` records a deployment on success; verified by reading back the ConfigMap.
- [ ] M3: `deployments list NAME` prints the table; `deployments logs NAME [ID]` streams logs.
- [ ] M4: `nagarectl-test` green; end-to-end transcript captured.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Generalize the pure layer of `Nagare.Static.Release` to a configurable ConfigMap name
  rather than copying it, and store app deployments under `nagare-app-deployments-<app>`.
  Rationale: The static release log is already a proven, unit-tested newest-first/capped/current-marked
  ConfigMap-as-JSON store; app deployments need exactly the same behavior. Reuse keeps one
  implementation and one set of tests. A distinct ConfigMap name keeps app and static histories
  separate. The concrete approach is in M1.
  Date: 2026-06-10

- Decision: A deployment id is the image tag (the same value `nagarectl deploy` already computes via
  `Nagare.Image.computeTag`, default UTC `YYYYMMDD-HHMMSS`), exactly as a static `releaseId` is the
  image tag today.
  Rationale: The tag already uniquely identifies a build/deploy and is the value the user passes to
  `--tag`; reusing it means `deployments logs NAME <ID>` can map an id to its artifacts without a second
  identifier scheme. It mirrors `StaticRelease.releaseId == imageTag`.
  Date: 2026-06-10

- Decision: `deployments logs NAME [ID]` maps a deployment id to a Knative *revision* by reading the
  Service's revisions and matching the one whose container image tag equals the deployment id; with no
  id it streams the live revision (no revision selector).
  Rationale: Knative names revisions `<app>-NNNNN`, not by tag, so the id→revision mapping must be
  resolved at query time. Matching on the image tag is robust and needs no extra bookkeeping. If no
  revision still exists for an old id (Knative garbage-collected it), report that clearly rather than
  streaming nothing.
  Date: 2026-06-10


## Context and Orientation

This plan lives in `cli/nagarectl`. You need to understand the existing static release store (which you
will generalize), the deploy entry point (where you will hook recording), and the kubectl/log patterns.

**The static release store — `cli/nagarectl/src/Nagare/Static/Release.hs`.** This is the template. It
cleanly separates a *pure* layer from a thin *IO* layer:

- Types: `StaticRelease { releaseId, siteName, namespace, image, imageTag, url, source :: Maybe Text,
  createdAt :: UTCTime }` and `StaticReleaseLog { current :: Maybe Text, releases :: [StaticRelease] }`,
  both with hand-written Aeson `ToJSON`/`FromJSON`.
- Pure ops: `emptyReleaseLog`, `historyCap = 50`, `addRelease` (make it current, dedup same id, sort
  newest-first by `createdAt`, cap), `findRelease`, `formatReleasesTable` (aligned table, live row
  marked `*`).
- ConfigMap shape: `configMapName site = "nagare-static-releases-" <> site`,
  `releaseDataKey = "releases.json"`, `renderReleaseConfigMap` (emit a ConfigMap whose `data."releases.json"`
  is the log JSON as a string — `kubectl apply -f` accepts JSON), `extractReleaseLog` (defensively pull
  the inner JSON back out, empty log if absent, `Left` if malformed).
- IO: `readReleaseLog site ns` (`kubectl get configmap <name> -n <ns> -o json`; missing CM → empty log;
  malformed → `Left`), `writeReleaseLog site ns log` (`kubectl apply` the rendered ConfigMap, via
  `Nagare.Deploy.applyManifests`), and the runtime-agnostic
  `recordReleaseFor :: Text -> Text -> Text -> Text -> Text -> Maybe Text -> IO (Either Text ())`
  (args: image, tag, url, name, ns, source) which reads, `addRelease`s, and writes — used by both the
  static and server deploy paths today.

The whole module is exposed from `cli/nagarectl/nagarectl.cabal`. Note that `configMapName` is the only
site-specific piece; everything else is already runtime-agnostic.

**The deploy entry point — `cli/nagarectl/app/Main.hs`, `runDeploy`.** It loads a `Deployment`,
computes the image tag (`resolveTag (dopts ^. #tag)`), resolves the build spec, renders the Service and
DomainMappings, computes `url = serviceUrl dep bd`, and in the non-dry-run branch builds/pushes,
`applyManifests`, `waitForReady name ns`, and prints `Deployed: <url>`. The app deploy path records
*nothing* today — contrast `runSiteDeploy`, which calls `deployStaticProduction`/`deployServerProduction`,
which call `recordReleaseFor`. You will add a record step in `runDeploy` after `waitForReady`. Note
`DeployOpts` already has a `tag` field but **no `source` field** — the site path has `--source` but the
app `deploy` does not; you will add a `--source` option to `DeployOpts` so app deployments can carry
provenance (matching the site path).

**The image ref.** `Nagare.Image.imageRef :: Deployment -> Text -> Text` builds the full
`repo:tag` reference; `imageRefText (dep ^. #image)` is the repo alone. For the record, store the repo
in `image` and the tag in `imageTag` exactly as the static path does.

**Knative revisions for `deployments logs`.** Revisions are
`kubectl get revisions -n <ns> -l serving.knative.dev/service=<app> -o json`; each item has
`.metadata.name` (e.g. `notes-00003`) and `.spec.containers[0].image` (which ends in `:<tag>`). To map
a deployment id (a tag) to a revision name, find the item whose image ends with `:<id>`. Logs for a
specific revision use the selector `serving.knative.dev/service=<app>,serving.knative.dev/revision=<rev>`
— exactly the `LogTarget` shape from `docs/plans/30-nagarectl-app-lifecycle-commands.md`.

**The test suite.** `cli/nagarectl/test/Spec.hs` (tasty + tasty-hunit), grouped by module, tests pure
helpers. The existing `Nagare.Static.Release` tests (release-log JSON round-trip, `addRelease` history
management) are the template for your deployment-store tests.


## Plan of Work

### Milestone 1 — Per-app deployment history store

Scope: make the release-store machinery usable for apps under a distinct ConfigMap name, with pure-layer
tests. After this milestone you can read and write an app's deployment log in code.

Choose the lower-risk of two approaches (recommended: **(a) parameterize**):

(a) **Parameterize the existing module.** In `cli/nagarectl/src/Nagare/Static/Release.hs`, change the
hard-coded `configMapName` to take a name *prefix*, and have the IO functions accept it. Concretely,
add a small record or just thread a prefix `Text`:

```haskell
configMapNameWith :: Text -> Text -> Text         -- prefix -> name -> configmap name
configMapNameWith prefix nm = prefix <> nm

-- keep the old name working for static callers:
configMapName :: Text -> Text
configMapName = configMapNameWith "nagare-static-releases-"
```

Then add app-flavored wrappers (in a new tiny module `cli/nagarectl/src/Nagare/App/Deployments.hs` to
keep names tidy) that reuse the pure `StaticRelease`/`StaticReleaseLog`/`addRelease`/`findRelease`/
`formatReleasesTable`/`extractReleaseLog` and supply the prefix `"nagare-app-deployments-"`:

```haskell
module Nagare.App.Deployments
  ( appConfigMapName        -- "nagare-app-deployments-" <> app
  , readDeployments         -- :: Text -> Text -> IO (Either Text StaticReleaseLog)
  , writeDeployments        -- :: Text -> Text -> StaticReleaseLog -> IO ()
  , recordDeploymentFor     -- :: Text -> Text -> Text -> Text -> Text -> Maybe Text -> IO (Either Text ())
  , findDeployment          -- re-export of findRelease
  , formatDeploymentsTable  -- re-export of formatReleasesTable
  ) where
```

Implement `readDeployments`/`writeDeployments`/`recordDeploymentFor` by copying the bodies of
`readReleaseLog`/`writeReleaseLog`/`recordReleaseFor` but calling `configMapNameWith
"nagare-app-deployments-"`. To avoid literal duplication, prefer refactoring the static IO functions to
take the prefix and re-exporting; the simplest honest version that keeps static behavior byte-identical
is fine. Whatever you choose, **the static commands must keep passing their existing tests unchanged**.

(b) **(Rejected unless (a) proves messy)** copy the module wholesale into `Nagare.App.Deployments` with
the app ConfigMap name. Only fall back to this if generalizing (a) entangles the static module
awkwardly; record the choice in the Decision Log.

Add `Nagare.App.Deployments` (and any new export) to `cli/nagarectl/nagarectl.cabal`'s
`exposed-modules`.

Tests: add a `testGroup "Nagare.App.Deployments"` asserting `appConfigMapName "notes" ==
"nagare-app-deployments-notes"`; that a record round-trips through the same JSON path as
`StaticRelease`; and that `addRelease` ordering/cap behavior is reused (you can reuse the existing
`StaticRelease` round-trip assertions). Acceptance: `cabal test` green, including the *unchanged* static
tests.

### Milestone 2 — Record a deployment on `nagarectl deploy`

Scope: hook recording into the app deploy path. After this milestone every successful app deploy leaves
a record.

In `cli/nagarectl/app/Main.hs`:

- Add a `source :: !(Maybe String)` field to `DeployOpts` and a `--source` option to
  `deployOptsParser` (copy the `--source` option block from `siteDeployOptsParser`, whose help is
  "Provenance to record with the release (e.g. a git SHA or branch)").

- In `runDeploy`, in the non-dry-run branch, after `waitForReady name ns` and before/after the
  `Deployed:` print, record the deployment:

  ```haskell
  let repo = imageRefText (dep ^. #image)
  rec <- recordDeploymentFor repo imageTag url name ns (T.pack <$> dopts ^. #source)
  case rec of
    Left warn -> TIO.hPutStrLn stderr ("nagarectl: " <> warn)  -- non-fatal: deploy already succeeded
    Right ()  -> pure ()
  TIO.putStrLn ("Deployed: " <> url)
  ```

  Use `imageTag` (the already-resolved tag, not the build-spec-resolved `effTag`, so a prebuilt image
  still records the deploy id the user sees) — match what the printed URL/tag semantics are; if a
  prebuilt image's deploy id should be its own tag, use `effTag` instead and note the choice. Recording
  must be **non-fatal**: a failed history write must not fail a successful deploy (mirror how
  `recordReleaseFor` returns `Left` as a warning).

Import `recordDeploymentFor` from `Nagare.App.Deployments`, `imageRefText` from `Nagare.Dsl.Types`, and
`stderr`/`hPutStrLn` as already imported.

Acceptance: after `nagarectl deploy`, `kubectl get configmap nagare-app-deployments-<app> -n <ns> -o
json` shows the record; a second deploy with a different tag adds a second record and updates `current`.

### Milestone 3 — `deployments list` and `deployments logs`

Scope: the two read commands.

In `cli/nagarectl/app/Main.hs`, add a top-level `command "deployments" deploymentsCmd` with a nested
subparser:

```haskell
deploymentsCmd = info (deploymentsSub <**> helper)
  (fullDesc <> progDesc "Application deployment history and logs")
deploymentsSub = subparser
  ( command "list" (info (DeploymentsList <$> depCommonOpts <**> helper)
                     (progDesc "List recorded deployments for an app"))
 <> command "logs" (info (DeploymentsLogs <$> depLogsOpts <**> helper)
                     (progDesc "Stream logs for the live or a specific past deployment"))
  )
```

Options: `DeploymentsList` takes a positional `NAME` and optional `-n/--namespace` (default `personal`).
`DeploymentsLogs` takes a positional `NAME`, an optional positional `DEPLOYMENT_ID`, `-n/--namespace`,
and `--follow`/`--tail` like `app logs`.

Handlers:

- `runDeploymentsList`: resolve `(name, ns)`; `readDeployments name ns >>= either dieT (TIO.putStr .
  formatDeploymentsTable)`.
- `runDeploymentsLogs`: resolve `(name, ns)`. If no id: build a `LogTarget` with `ltRevision = Nothing`
  and `streamServiceLogs`. If an id is given: resolve it to a revision name by
  `resolveRevisionForTag ns name id` (a new helper: `kubectl get revisions -n <ns> -l
  serving.knative.dev/service=<name> -o json`, find the item whose `.spec.containers[0].image` ends with
  `:<id>`, return its `.metadata.name`). If found, stream with `ltRevision = Just rev`; if not found,
  `dieT ("no live revision for deployment " <> id <> " (it may have been garbage-collected)")`.

Reuse `streamServiceLogs`/`LogTarget` and `appIdentityOrDie` from `Nagare.App`
(`docs/plans/30-nagarectl-app-lifecycle-commands.md`). **If EP-30 has not landed**, create
`cli/nagarectl/src/Nagare/App.hs` with exactly the `LogTarget`/`streamServiceLogs`/`appIdentityOrDie`
signatures listed in that plan's Interfaces section and use them here; EP-30 will then reuse them. Put
`resolveRevisionForTag` in `Nagare.App.Deployments` (it is deployment-history-specific).

Add the `Command` constructors and `main` dispatch arms.

Acceptance: `nagarectl deployments list NAME` prints the table; `nagarectl deployments logs NAME`
streams live logs; `nagarectl deployments logs NAME <ID>` streams the matching revision's logs or errors
clearly if its revision is gone.

### Milestone 4 — Tests green and an end-to-end transcript

`cabal test` in `cli/nagarectl`. Against a cluster: deploy twice with `--tag a` then `--tag b`, run
`deployments list NAME` (two rows, `b` starred), `deployments logs NAME`, and `deployments logs NAME a`.
Paste the transcript into Concrete Steps. If no cluster is reachable, validate the pure helpers and
arg-builders by unit test and defer the live run, recording that here.


## Concrete Steps

From the repo root (prefix with `nix develop -c` as needed):

```bash
cd cli/nagarectl
cabal build
cabal test
```

End-to-end (with a cluster and `NAGARE_GHC_ENVIRONMENT` set):

```bash
cd <an example app project>
nagarectl deploy --tag 20260610-100000 --source "$(git rev-parse --short HEAD)"
nagarectl deploy --tag 20260610-110000 --source "$(git rev-parse --short HEAD)"
nagarectl deployments list notes
nagarectl deployments logs notes                 # live
nagarectl deployments logs notes 20260610-100000 # the earlier deployment's revision
```

Expected `deployments list` shape (mirrors `site releases`):

```text
  RELEASE ID        CREATED                SOURCE      URL
* 20260610-110000   2026-06-10 11:00:00 …  a1b2c3d     https://notes.personal.apps.example.com
  20260610-100000   2026-06-10 10:00:00 …  a1b2c3d     https://notes.personal.apps.example.com
```


## Validation and Acceptance

1. `cabal test` in `cli/nagarectl` passes, including the new deployment-store cases AND the unchanged
   static-release cases (proving the generalization did not regress static behavior).
2. After a successful `nagarectl deploy`, the ConfigMap `nagare-app-deployments-<app>` exists and
   contains the record; a second deploy adds a second record and updates `current`.
3. `nagarectl deployments list NAME` prints the history newest-first with the live deployment starred.
4. `nagarectl deployments logs NAME` streams the live revision's logs; `nagarectl deployments logs NAME
   <ID>` streams the logs of the revision that deployment produced, or errors clearly when that revision
   no longer exists.

If no cluster is reachable, items 2–4 are validated by the pure helpers (`addRelease`, table
formatting, the id→revision matcher run against hand-written revision JSON) plus `--help` inspection,
with the live run deferred and noted here.


## Idempotence and Recovery

Recording is idempotent on the deployment id: `addRelease` dedups a record with the same id and re-sorts,
so re-deploying the same tag updates rather than duplicates. A failed history write is non-fatal and
leaves the prior history intact (`recordReleaseFor`/`recordDeploymentFor` returns `Left` without
overwriting on a malformed existing log). `deployments list`/`logs` are read-only. The history ConfigMap
is deleted by `nagarectl app delete` (sibling plan
`docs/plans/30-nagarectl-app-lifecycle-commands.md`); deleting an app therefore also clears its history,
which is the intended behavior. Recover from a bad edit with `git checkout`.


## Interfaces and Dependencies

Existing libraries (already in `cli/nagarectl/nagarectl.cabal`): `aeson`, `containers`, `cradle`,
`text`, `time`, `nagare-dsl`, `optparse-applicative`. No new dependency.

Signatures that must exist at the end of this plan:

```haskell
-- Nagare.App.Deployments (new module)
appConfigMapName       :: Text -> Text                       -- "nagare-app-deployments-" <> app
readDeployments        :: Text -> Text -> IO (Either Text StaticReleaseLog)
writeDeployments       :: Text -> Text -> StaticReleaseLog -> IO ()
recordDeploymentFor    :: Text -> Text -> Text -> Text -> Text -> Maybe Text -> IO (Either Text ())
findDeployment         :: Text -> StaticReleaseLog -> Maybe StaticRelease   -- re-export of findRelease
formatDeploymentsTable :: StaticReleaseLog -> Text                          -- re-export of formatReleasesTable
resolveRevisionForTag  :: Text -> Text -> Text -> IO (Maybe Text)           -- ns -> app -> id -> revision name

-- Nagare.Static.Release (generalized; static callers unchanged)
configMapNameWith :: Text -> Text -> Text
configMapName     :: Text -> Text             -- = configMapNameWith "nagare-static-releases-"

-- Reused from Nagare.App (docs/plans/30-...); created here if that plan has not landed:
data LogTarget = LogTarget { ltNamespace :: Text, ltService :: Text, ltRevision :: Maybe Text
                           , ltFollow :: Bool, ltTail :: Maybe Int }
streamServiceLogs :: LogTarget -> IO ()
appIdentityOrDie  :: FilePath -> IO (Text, Text)
```

Integration: this plan reuses `StaticRelease`/`StaticReleaseLog`/`addRelease`/`findRelease`/
`formatReleasesTable`/`extractReleaseLog` from `Nagare.Static.Release`, the `applyManifests` IO from
`Nagare.Deploy`, and `LogTarget`/`streamServiceLogs`/`appIdentityOrDie` from `Nagare.App`. The app
history ConfigMap name `nagare-app-deployments-<app>` is the contract that
`docs/plans/30-nagarectl-app-lifecycle-commands.md`'s `app delete` removes; keep the name in sync.
