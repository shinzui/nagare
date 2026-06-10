---
id: 30
slug: nagarectl-app-lifecycle-commands
title: "nagarectl app lifecycle commands"
kind: exec-plan
created_at: 2026-06-10T00:33:39Z
intention: "intention_01ktqexbzyeb2bfka9q38w3gmx"
master_plan: "docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md"
---

# nagarectl app lifecycle commands

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This plan is a child of the MasterPlan at
`docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md`. It is self-contained: you can
implement it without reading the MasterPlan or any sibling plan. It introduces a new module
(`Nagare.App`) whose helpers a sibling plan
(`docs/plans/31-application-deployment-history-and-deployments-commands.md`) also reuses — that
relationship is noted but creates no dependency in this direction; this plan stands alone.


## Purpose / Big Picture

Today `nagarectl` can only *create* an application. `nagarectl deploy` builds, pushes, applies a
Knative Service, waits for readiness, and prints a URL — and then there is nothing more the tool can
do. To see which apps exist, inspect one, read its logs, restart it, take it offline, or remove it, an
operator must drop to raw `kubectl` and know the Knative resource names by heart. This plan closes that
gap with six lifecycle commands under a new `app` namespace:

```text
nagarectl app list
nagarectl app get NAME
nagarectl app logs NAME [--follow]
nagarectl app restart NAME
nagarectl app stop NAME
nagarectl app delete NAME
```

After this plan, an operator can run `nagarectl app list` and see every Nagare-managed application in
a namespace with its URL and readiness; `nagarectl app get notes` to see one app's image, latest
revision, URL, and ready state; `nagarectl app logs notes --follow` to tail the running container's
logs; `nagarectl app restart notes` to roll a fresh revision; `nagarectl app stop notes` to take it
offline (recoverably); and `nagarectl app delete notes` to remove the Service, its DomainMappings, and
its deployment-history record. All of it goes through the same `kubectl` shell-out machinery the rest
of `nagarectl` already uses, so it works against the same cluster `nagarectl deploy` targets.

You can see it working end-to-end: deploy an app with `nagarectl deploy`, then `nagarectl app list`
shows it, `nagarectl app get NAME` describes it, `nagarectl app logs NAME` prints its logs,
`nagarectl app stop NAME` makes its URL stop serving, and `nagarectl app delete NAME` removes it so a
subsequent `app list` no longer shows it.


## Progress

- [x] M1: `Nagare.App` module with `appIdentityOrDie`, `streamServiceLogs`, and the pure helpers; added to the cabal library; unit tests for the pure helpers. (2026-06-10)
- [ ] M2: `app list` and `app get` wired into the CLI parser and working against the cluster.
- [ ] M3: `app logs [--follow]`, `app restart`, `app stop`, `app delete` wired and working.
- [ ] M4: `nagarectl-test` green; manual end-to-end transcript captured in this plan.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: `app stop` takes the app offline by making the Knative Service cluster-local in a
  recoverable way. Concretely, implement stop as `kubectl patch ksvc <name> -n <ns> --type=merge` to
  add the label `networking.knative.dev/visibility: cluster-local` (which removes the public route so
  the public URL stops serving) — and document that `nagarectl deploy` or `nagarectl app restart NAME`
  restores public serving (the renderer re-applies a Service without that label; `restartApp` also
  strips it). If, during implementation, the `cluster-local` label proves unsuitable on this
  single-node Kourier setup, fall back to deleting the Service while preserving the deployment-history
  ConfigMap (so the app still appears in `deployments list` and can be re-deployed). Record the final
  mechanism here when chosen.
  Rationale: Knative has no native pause. The MasterPlan fixes the *semantics* — offline but
  recoverable, history preserved — and leaves the exact `kubectl` mechanism to this plan. The
  `cluster-local` label is the least destructive way to stop public traffic without losing the Service.
  Date: 2026-06-10

- Decision: `app restart` forces a new revision by patching a Nagare-owned annotation
  (`nagare.dev/restartedAt`) on the Service's `spec.template.metadata.annotations`, which Knative
  treats as a template change and rolls a fresh revision. The annotation value is a timestamp string
  supplied by the caller (computed via `Nagare.Image.computeTag`, which already yields a UTC
  `YYYYMMDD-HHMMSS` string) so the function stays free of hidden clock calls.
  Rationale: Annotating the template is the standard, side-effect-free way to force a Knative rollout
  without changing the image or rebuilding. Using the existing `computeTag` keeps timestamp formatting
  consistent with the rest of the tool.
  Date: 2026-06-10

- Decision: `app list` filters Knative Services by the label `nagare.dev/managed-by=nagarectl` (stamped
  by the renderer in `docs/plans/29-extended-application-model-health-checks-resource-limits-multiple-domains.md`).
  When run against a cluster whose Services predate that label, the filter yields nothing; `app list`
  therefore accepts `--all` to list every Knative Service in the namespace unfiltered, and prints a
  one-line note when the filtered list is empty suggesting `--all`.
  Rationale: The label is the clean way to distinguish Nagare apps from other Knative workloads, but
  the command must remain useful before every app has been re-deployed with the label.
  Date: 2026-06-10

- Decision: Every `app NAME` command takes a required positional `NAME` and an optional `-n/--namespace`
  (default `personal`); it does *not* require a config file in the working directory. A `--file` config
  is accepted only where it adds value (e.g. `app get` enriching output with configured fields, or
  `app delete` reading the declared domains).
  Rationale: Lifecycle operations target a *deployed* app by name; requiring a `Config.hs` to act on a
  live app would be friction. Defaulting the namespace to `personal` matches `defaultNamespace` in the
  DSL.
  Date: 2026-06-10


## Context and Orientation

This plan lives entirely in the `cli/nagarectl` package (the CLI) and touches no DSL types. You need to
understand four things: how the CLI is structured, how it shells out, how the static-site commands
already implement the exact patterns you will copy, and what Knative resource names/labels to use.

**The CLI structure.** `cli/nagarectl/app/Main.hs` is the entry point. It uses
`optparse-applicative`. A sum type `Command` enumerates everything the tool does (`Deploy`,
`SiteDeploy`, `SiteReleases`, `SiteRollback`, `SitePreviewDeploy`, `SitePreviewList`,
`SitePreviewDelete`). `opts :: ParserInfo Command` builds a top-level `subparser` with `command
"deploy" …` and `command "site" …`; `site` is itself a nested `subparser`. `main` does
`execParser opts >>= \case …` dispatching each constructor to a `runX` handler. You will add a new
top-level `command "app" appCmd` whose nested subparser has `list/get/logs/restart/stop/delete`, new
`Command` constructors, and new `runX` handlers. The file already has reusable helpers you will reuse:

- `ghcEnvOpt :: Parser (Maybe FilePath)` and `provisionGhcEnv :: Maybe FilePath -> IO ()` — the config
  loader (`runghc`) needs a GHC package-environment file; commands that load a config call
  `provisionGhcEnv` first.
- `fileOpt :: FilePath -> Parser FilePath` and `defaultConfigFile = "nagare/Config.hs"` — the `--file`
  option for commands that read a config.
- `baseDomainOpt` / `resolveBaseDomain` — resolve the apps base domain for URL computation.
- `dieT :: Text -> IO a` — print `nagarectl: <msg>` to stderr and `exitFailure`.
- `orDie :: Either Text a -> IO a` — exit on a `Left`.
- `siteIdentityOrDie :: FilePath -> IO (Text, Text)` — loads a *site* config and returns its
  (name, namespace). You will write the app analogue, `appIdentityOrDie`, in the new `Nagare.App`
  module, mirroring this.

**How it shells out.** All subprocess calls go through the `cradle` library (already a dependency).
The patterns, copied from `cli/nagarectl/src/Nagare/Static/Preview.hs` and
`cli/nagarectl/src/Nagare/Deploy.hs`:

```haskell
import Cradle
-- Fire and forget (inherit stdout/stderr); throws on non-zero exit:
run_ $ cmd "kubectl" & addArgs ["delete", "ksvc", T.unpack name, "-n", T.unpack ns, "--ignore-not-found"]
-- Capture stdout, tolerate non-zero exit:
(exitCode, StdoutRaw out) <- run $ cmd "kubectl" & addArgs [...] & silenceStderr
-- StdoutUntrimmed / StdoutRaw are cradle output wrappers; pattern-match to get the bytes/text.
```

`run_` streams the child's stdout/stderr straight through (what you want for `kubectl logs --follow`).
`run` captures output (what you want for `kubectl get -o json`).

**The precedents to copy.** `cli/nagarectl/src/Nagare/Static/Preview.hs` already implements the two
hardest shapes:

- `listPreviews :: Text -> Text -> IO [Text]` runs `kubectl get ksvc -n <ns> -o name`, captures stdout,
  splits into lines, strips the `service.serving.knative.dev/` resource prefix, and filters by a name
  prefix. Your `app list` is the same minus the prefix filter, plus a label selector.
- `deletePreview :: Text -> Text -> Text -> IO ()` runs `kubectl delete ksvc <name> -n <ns>
  --ignore-not-found` and `kubectl delete domainmapping <domain> -n <ns> --ignore-not-found`. Your
  `app delete` is the same shape (delete the Service, its DomainMappings, and the history ConfigMap).

`cli/nagarectl/app/Main.hs`'s `runSiteReleases`/`runSiteRollback` show the load-config-then-act flow
you will mirror where a config is involved. `cli/nagarectl/src/Nagare/Static/Release.hs`'s
`formatReleasesTable` (with its `pad` helper) and `extractReleaseLog` (defensive Aeson walking) are the
templates for your table formatting and JSON extraction.

**Knative names and labels you will use.**

- A Nagare app is a Knative Service named `<app>` in namespace `<ns>` (default `personal`). Resource
  type abbreviation: `ksvc`.
- Pods for a Service carry the label `serving.knative.dev/service=<app>`; the app's container is named
  `user-container`. So logs are `kubectl logs -l serving.knative.dev/service=<app> -n <ns>
  -c user-container [--follow] [--tail=N]`.
- Each Service revision carries `serving.knative.dev/revision=<revision>`; you can further pin logs to
  one revision by adding that selector (used by the sibling `deployments logs` command).
- The renderer stamps `metadata.labels.nagare.dev/managed-by: nagarectl`; list with
  `kubectl get ksvc -n <ns> -l nagare.dev/managed-by=nagarectl -o json`.
- The app's URL and Ready condition are in `kubectl get ksvc <app> -n <ns> -o json` under
  `.status.url` and `.status.conditions[] | select(.type=="Ready")`; the latest ready revision is
  `.status.latestReadyRevisionName`; the image is `.spec.template.spec.containers[0].image`.

**The test suite.** `cli/nagarectl/test/Spec.hs` uses `tasty` + `tasty-hunit`, grouped by module
(`testGroup "Nagare.Static.Preview" [...]`, etc.). Tests cover *pure* helpers (naming, parsing,
formatting) — not the `kubectl` IO. You will add a `testGroup "Nagare.App"` for the pure helpers you
introduce, following the existing assertion style (`@?=`, `assertBool`).

**The cabal file.** `cli/nagarectl/nagarectl.cabal` lists library `exposed-modules` (currently
`Nagare.Build`, `Nagare.Deploy`, `Nagare.Image`, `Nagare.Server.*`, `Nagare.Static.*`). You will add
`Nagare.App` there. The `nagarectl` executable stanza already depends on `optparse-applicative`; the
library depends on `cradle`, `nagare-dsl`, `text`, `time`, `aeson`, `containers`, etc.


## Plan of Work

### Milestone 1 — The `Nagare.App` module and pure helpers

Scope: create `cli/nagarectl/src/Nagare/App.hs` with the shared identity loader, the log streamer, and
the pure parse/format helpers the commands need, plus unit tests for the pure parts. After this
milestone the module compiles and is exported, but no command uses it yet.

Create `cli/nagarectl/src/Nagare/App.hs` exporting:

```haskell
module Nagare.App
  ( -- identity
    appIdentityOrDie
    -- log streaming
  , LogTarget (..)
  , streamServiceLogs
  , logArgs
    -- live-state queries
  , AppSummary (..)
  , listManagedApps
  , getAppSummary
  , extractAppSummary
  , parseServiceNames
  , formatAppList
    -- lifecycle ops
  , restartApp
  , restartPatch
  , stopApp
  , deleteApp
  ) where
```

Implement:

- `appIdentityOrDie :: FilePath -> IO (Text, Text)` — load a `Deployment` config and return
  `(serviceNameText name, namespaceText namespace)`. Mirror `siteIdentityOrDie` in `Main.hs` but use
  `Nagare.Dsl.Load.loadDeployment` and `Nagare.Dsl.Load.renderLoadError`. On a `Left`, print
  `nagarectl: <renderLoadError err>` to stderr and `exitFailure` (a local `dieT` copy is fine; the
  codebase already duplicates tiny die helpers).

- `data LogTarget = LogTarget { ltNamespace :: Text, ltService :: Text, ltRevision :: Maybe Text,
  ltFollow :: Bool, ltTail :: Maybe Int }` and
  `streamServiceLogs :: LogTarget -> IO ()` — build the kubectl args and `run_` them (streaming):

  ```haskell
  streamServiceLogs t = run_ $ cmd "kubectl" & addArgs (logArgs t)

  logArgs :: LogTarget -> [String]    -- pure, exported for tests
  logArgs t =
    [ "logs"
    , "-l", T.unpack (selector t)
    , "-n", T.unpack (ltNamespace t)
    , "-c", "user-container"
    ]
    <> maybe [] (\n -> ["--tail", show n]) (ltTail t)
    <> ["--follow" | ltFollow t]
    where
      selector x =
        "serving.knative.dev/service=" <> ltService x
          <> maybe "" (\r -> ",serving.knative.dev/revision=" <> r) (ltRevision x)
  ```

  `streamServiceLogs` is the Integration Point the sibling `deployments logs` command reuses by passing
  a `ltRevision`.

- `data AppSummary = AppSummary { asName :: Text, asUrl :: Maybe Text, asReady :: Maybe Bool,
  asLatestRevision :: Maybe Text, asImage :: Maybe Text }`.

- `parseServiceNames :: Text -> [Text]` (pure, tested) — split `kubectl get … -o name` output into
  lines, drop blanks, strip the `service.serving.knative.dev/` prefix (copy the exact strip from
  `Static/Preview.hs`'s `listPreviews`).

- `listManagedApps :: Text -> Bool -> IO [Text]` (namespace, allUnfiltered) — run
  `kubectl get ksvc -n <ns> [-l nagare.dev/managed-by=nagarectl] -o name`, capture stdout,
  `parseServiceNames` it. (For `app list`'s table, prefer a single `kubectl get ksvc … -o json` and map
  `extractAppSummary` over `.items` to avoid one kubectl call per app.)

- `getAppSummary :: Text -> Text -> IO (Either Text AppSummary)` (namespace, name) — run
  `kubectl get ksvc <name> -n <ns> -o json`, capture stdout; on non-zero exit return
  `Left "no such app: <name>"`; on success `extractAppSummary` it.

- `extractAppSummary :: ByteString -> Either Text AppSummary` (pure, tested) — Aeson-decode and pull
  `.metadata.name`, `.status.url`, the Ready condition (`.status.conditions[]` where
  `type=="Ready"`, ready iff `status=="True"`), `.status.latestReadyRevisionName`, and
  `.spec.template.spec.containers[0].image`. Use the defensive walking style of
  `Nagare.Static.Release.extractReleaseLog` (pattern-match `Aeson.Object`/`Aeson.Array`, return `Left`
  on malformed shape, never crash). This must also work on a single item from a list response, so write
  it against one Service object.

- `formatAppList :: [AppSummary] -> Text` (pure, tested) — aligned `NAME`/`READY`/`URL` table, reusing
  the `pad` approach from `formatReleasesTable`.

- `restartApp :: Text -> Text -> Text -> IO ()` (namespace, name, stamp) — patch the template
  annotation to force a revision, and strip the cluster-local label so restart implies "back online":

  ```haskell
  restartApp ns name stamp =
    run_ $ cmd "kubectl" & addArgs
      [ "patch", "ksvc", T.unpack name, "-n", T.unpack ns, "--type=merge"
      , "-p", T.unpack (restartPatch stamp) ]

  restartPatch :: Text -> Text     -- pure, tested; JSON merge patch
  restartPatch stamp =
    "{\"metadata\":{\"labels\":{\"networking.knative.dev/visibility\":null}},"
      <> "\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"nagare.dev/restartedAt\":\""
      <> stamp <> "\"}}}}}"
  ```

  (A `null` value in a merge patch deletes that label, undoing `stop`.)

- `stopApp :: Text -> Text -> IO ()` — patch to add the cluster-local visibility label (per the
  Decision Log):

  ```haskell
  stopApp ns name =
    run_ $ cmd "kubectl" & addArgs
      [ "patch", "ksvc", T.unpack name, "-n", T.unpack ns, "--type=merge"
      , "-p", "{\"metadata\":{\"labels\":{\"networking.knative.dev/visibility\":\"cluster-local\"}}}" ]
  ```

  Confirm the exact label key against the cluster's Knative version during implementation; the Decision
  Log records the fallback.

- `deleteApp :: Text -> Text -> [Text] -> IO ()` (namespace, name, domains) — delete the Service, each
  DomainMapping, and the history ConfigMap (`nagare-app-deployments-<name>`, owned by the sibling plan)
  with `--ignore-not-found` so it works whether or not that plan has landed:

  ```haskell
  deleteApp ns name domains = do
    run_ $ cmd "kubectl" & addArgs ["delete", "ksvc", T.unpack name, "-n", T.unpack ns, "--ignore-not-found"]
    forM_ domains $ \d ->
      run_ $ cmd "kubectl" & addArgs ["delete", "domainmapping", T.unpack d, "-n", T.unpack ns, "--ignore-not-found"]
    run_ $ cmd "kubectl" & addArgs ["delete", "configmap", T.unpack ("nagare-app-deployments-" <> name), "-n", T.unpack ns, "--ignore-not-found"]
  ```

Add `Nagare.App` to `exposed-modules` in `cli/nagarectl/nagarectl.cabal`.

Add a `testGroup "Nagare.App"` in `cli/nagarectl/test/Spec.hs` covering: `parseServiceNames` strips the
prefix and drops blank lines; `logArgs` produces the expected selector with and without a revision and
with/without `--follow`/`--tail`; `restartPatch` produces valid JSON containing the stamp and a null
visibility; `extractAppSummary` on a small hand-written ksvc JSON returns the expected `AppSummary`;
`formatAppList` aligns columns. Acceptance: `cabal test` green in `cli/nagarectl`.

### Milestone 2 — `app list` and `app get`

Scope: wire the two read commands into the parser and `main`. After this milestone an operator can list
and inspect apps.

In `cli/nagarectl/app/Main.hs`:

- Add `Command` constructors `AppList AppListOpts | AppGet AppGetOpts`. Define option records:
  `AppListOpts { namespace :: Maybe String, allApps :: Bool }` (`-n/--namespace`, `--all`);
  `AppGetOpts { nameArg :: String, namespace :: Maybe String, file :: FilePath, ghcEnv :: Maybe FilePath }`
  (positional `NAME`, optional `-n`, optional `--file` for enrichment).

- Add the nested subparser and a top-level `command "app" appCmd`:

  ```haskell
  appCmd = info (appSubparser <**> helper)
             (fullDesc <> progDesc "Application lifecycle: list, get, logs, restart, stop, delete")
  appSubparser = subparser
    ( command "list"    (info (AppList <$> appListOptsParser <**> helper)    (progDesc "List Nagare-managed apps in a namespace"))
   <> command "get"     (info (AppGet <$> appGetOptsParser <**> helper)      (progDesc "Show one app's image, revision, URL, and readiness"))
   <> command "logs"    (info (AppLogs <$> appLogsOptsParser <**> helper)    (progDesc "Stream an app's container logs"))
   <> command "restart" (info (AppRestart <$> appNameOptsParser <**> helper) (progDesc "Roll a fresh revision"))
   <> command "stop"    (info (AppStop <$> appNameOptsParser <**> helper)    (progDesc "Take the app offline (recoverable)"))
   <> command "delete"  (info (AppDelete <$> appDeleteOptsParser <**> helper)(progDesc "Delete the app, its domains, and its history"))
    )
  ```

- Handlers:
  - `runAppList opts`: `let ns = maybe "personal" T.pack (opts ^. #namespace)`; one
    `kubectl get ksvc -n <ns> [-l nagare.dev/managed-by=nagarectl] -o json` (label unless `--all`); map
    `extractAppSummary` over the items; `TIO.putStr (formatAppList summaries)`. If the filtered list is
    empty, print a hint to try `--all`.
  - `runAppGet opts`: resolve `ns` (from `-n` or default) and `name` (positional);
    `getAppSummary ns name >>= either dieT printAppSummary`. `printAppSummary` prints aligned Name/
    Ready/URL/Revision/Image lines. If `--file` resolves to a readable config, additionally load it
    (`loadDeployment`) and print configured domains, health check, and limits — this is the only place
    EP-29's richer model is read; guard it so `app get` works without a config.

Acceptance: `nagarectl app list` prints a table of managed apps; `nagarectl app get <name>` prints
details; an unknown name → `nagarectl: no such app: <name>` and exit 1.

### Milestone 3 — `app logs`, `app restart`, `app stop`, `app delete`

Scope: wire the four mutating/streaming commands.

Add `Command` constructors `AppLogs AppLogsOpts | AppRestart AppNameOpts | AppStop AppNameOpts |
AppDelete AppDeleteOpts`, option records (`AppLogsOpts { nameArg :: String, namespace :: Maybe String,
follow :: Bool, tailN :: Maybe Int }`; `AppNameOpts { nameArg :: String, namespace :: Maybe String }`;
`AppDeleteOpts` adds optional `file`/`ghcEnv`), and handlers:

- `runAppLogs`: build a `LogTarget` (`ltRevision = Nothing`, `ltFollow = follow`, `ltTail =` `Nothing`
  when following else `Just (fromMaybe 200 tailN)`); call `streamServiceLogs`.
- `runAppRestart`: `stamp <- computeTag` (import from `Nagare.Image`); `restartApp ns name stamp`;
  `waitForReady name ns` (import from `Nagare.Deploy`); print `Restarted: <name>`.
- `runAppStop`: `stopApp ns name`; print
  `Stopped <name> (run 'nagarectl deploy' or 'nagarectl app restart <name>' to restore public serving)`.
- `runAppDelete`: determine the app's domains — if `--file` resolves, load the config and read
  `domains` (map `domainText . (^. #domain)` over the `DomainSpec` list from EP-29; if EP-29 has not
  landed, read the single `domain`); otherwise query the cluster:
  `kubectl get domainmapping -n <ns> -o json`, keep those whose `.spec.ref.name == name`, take their
  `.metadata.name`. Then `deleteApp ns name domainList`; print `Deleted <name>`.

Add the `main` dispatch arms for all four.

Acceptance: `app restart` yields a new revision; `app stop` makes the public URL stop serving;
`app delete` removes the Service so `app list` no longer shows it.

### Milestone 4 — Tests green and an end-to-end transcript

Run `cabal test` in `cli/nagarectl`. Then, against a reachable cluster, run the full lifecycle once and
paste the transcript into Concrete Steps as evidence. If no cluster is reachable, record that the
`kubectl` paths were verified by `--help`/argument inspection and unit tests and that the live run is
deferred (as `docs/masterplans/4-application-build-modes-for-nagare.md` did for its cluster deploy).


## Concrete Steps

From the repo root (prefix with `nix develop -c` if `cabal`/`kubectl` are not on PATH):

```bash
cd cli/nagarectl
cabal build
cabal test
```

End-to-end (with a cluster and `NAGARE_GHC_ENVIRONMENT` set as `nagarectl deploy --help` documents):

```bash
cd <an example app project>
nagarectl deploy                       # create the app
nagarectl app list                     # see it
nagarectl app get notes                # inspect it
nagarectl app logs notes --tail 50     # read recent logs
nagarectl app logs notes --follow      # tail (Ctrl-C to stop)
nagarectl app restart notes            # roll a new revision
nagarectl app stop notes               # take offline
nagarectl app restart notes            # restore (also: nagarectl deploy)
nagarectl app delete notes             # remove it
nagarectl app list                     # gone
```

Expected `app list` output shape:

```text
  NAME              READY   URL
  notes             True    https://notes.personal.apps.example.com
  blog              True    https://blog.example.com
```

Expected `app get` output shape:

```text
Name:     notes
Ready:    True
URL:      https://notes.personal.apps.example.com
Revision: notes-00003
Image:    us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes:20260610-120000
```


## Validation and Acceptance

1. `cabal test` in `cli/nagarectl` passes, including the new `Nagare.App` pure-helper cases.
2. With a deployed app, `nagarectl app list` shows it (Nagare-managed only unless `--all`);
   `nagarectl app get NAME` prints URL, readiness, revision, and image; an unknown name errors cleanly
   with exit 1.
3. `nagarectl app logs NAME` prints recent container logs; `--follow` streams until interrupted.
4. `nagarectl app restart NAME` causes a new Knative revision; `nagarectl app stop NAME` makes the
   public URL stop serving while the Service still exists; `nagarectl app delete NAME` removes the
   Service, its DomainMappings, and its history ConfigMap, so `app list` no longer shows it.

If no cluster is reachable, items 2–4 are validated by unit tests of the pure arg-builders/parsers and
`--help` inspection, with the live run explicitly deferred and noted here.


## Idempotence and Recovery

`app list`/`app get`/`app logs` are read-only and safe to repeat. `app restart` is safe to repeat (each
run stamps a new annotation and rolls a revision, and strips the cluster-local label). `app stop` is
idempotent (patching an already-cluster-local Service is a no-op) and is reversed by `app restart` or
`nagarectl deploy`. `app delete` uses `--ignore-not-found` on every kubectl call, so deleting an
already-deleted app is a clean no-op. No local files are written; recover from a bad edit with
`git checkout`.


## Interfaces and Dependencies

Existing libraries (already in `cli/nagarectl/nagarectl.cabal`): `cradle` (subprocess), `nagare-dsl`
(config loading via `Nagare.Dsl.Load`, identity accessors via `Nagare.Dsl.Types`), `aeson` (parse
`kubectl -o json`), `text`, `time` (via `Nagare.Image.computeTag`), `optparse-applicative` (CLI). No
new dependency.

Signatures that must exist at the end of this plan (module `Nagare.App` in
`cli/nagarectl/src/Nagare/App.hs`):

```haskell
appIdentityOrDie :: FilePath -> IO (Text, Text)
data LogTarget = LogTarget { ltNamespace :: Text, ltService :: Text, ltRevision :: Maybe Text
                           , ltFollow :: Bool, ltTail :: Maybe Int }
streamServiceLogs :: LogTarget -> IO ()
logArgs :: LogTarget -> [String]                       -- pure, tested
data AppSummary = AppSummary { asName :: Text, asUrl :: Maybe Text, asReady :: Maybe Bool
                             , asLatestRevision :: Maybe Text, asImage :: Maybe Text }
listManagedApps   :: Text -> Bool -> IO [Text]
getAppSummary     :: Text -> Text -> IO (Either Text AppSummary)
extractAppSummary :: ByteString -> Either Text AppSummary   -- pure, tested
parseServiceNames :: Text -> [Text]                          -- pure, tested
formatAppList     :: [AppSummary] -> Text                    -- pure, tested
restartApp   :: Text -> Text -> Text -> IO ()
restartPatch :: Text -> Text                                 -- pure, tested
stopApp      :: Text -> Text -> IO ()
deleteApp    :: Text -> Text -> [Text] -> IO ()
```

Integration: `streamServiceLogs`/`appIdentityOrDie` are reused by
`docs/plans/31-application-deployment-history-and-deployments-commands.md` (its `deployments logs`
passes a `ltRevision`). The `nagare.dev/managed-by: nagarectl` label that `listManagedApps` filters on
is produced by `docs/plans/29-extended-application-model-health-checks-resource-limits-multiple-domains.md`;
this plan degrades to `--all` when that label is absent. The history ConfigMap `deleteApp` removes is
named/owned by EP-31 (`nagare-app-deployments-<name>`); deleting it here with `--ignore-not-found` is
safe whether or not EP-31 has landed.
