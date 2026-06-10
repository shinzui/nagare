---
id: 25
slug: nagarectl-env-and-secret-cli-commands
title: "nagarectl env and secret CLI commands"
kind: exec-plan
created_at: 2026-06-09T23:52:37Z
intention: "intention_01ktqcj5aseb1rx94fh6npnydv"
master_plan: "docs/masterplans/5-environment-and-secret-management-for-nagare.md"
---

# nagarectl env and secret CLI commands

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`nagarectl` is the command-line tool that deploys a Nagare app to a Kubernetes
cluster (Knative Serving). Today, the only way to give a running app an
environment variable — a named string the app reads from its environment, such
as `LOG_LEVEL=info` — or a secret — a sensitive named string such as
`DATABASE_URL=postgres://...` — is to edit the app's typed Haskell config file
(`nagare/Config.hs`), recompile it, and redeploy. There is no day-2 operation:
no way to add, change, or remove a variable without touching Haskell and
rebuilding the container image.

This plan delivers that missing operator surface. After it, an operator can run:

```text
nagarectl env list APP
nagarectl env set APP KEY VALUE
nagarectl env delete APP KEY
nagarectl env sync APP --file .env.production [--runtime] [--build] [--preview] [--merge | --reconcile-exact]
nagarectl secret set APP KEY            # value read from stdin, never argv
nagarectl secret list APP               # KEY names only, never values
nagarectl secret delete APP KEY
```

and the change takes effect by re-applying one tiny Kubernetes ConfigMap (for
env) or Secret (for secrets) that the app's running Service *already references*
through its `envFrom` list. `envFrom` is a Kubernetes mechanism that injects
every key/value pair of a named ConfigMap or Secret into a container as
environment variables; a sibling plan (EP-23, see Context) makes every rendered
Service reference the managed ConfigMap `nagare-env-<app>-runtime` and the
managed Secret `nagare-secret-<app>-runtime` with `optional: true` (so an app
whose store has never been written still deploys). Writing those resources from
the CLI is therefore all that is needed to change a running app's environment —
no Haskell edit, no image rebuild.

The user-visible behavior this plan enables and proves:

- `nagarectl env set notes FOO bar` followed by `nagarectl env list notes` shows
  `FOO=bar`.
- `nagarectl env sync notes --file .env --reconcile-exact` makes the store
  exactly the file's contents, dropping a key set earlier that is not in the
  file. The same command with `--merge` (the default) keeps such keys.
- `nagarectl secret set notes API_KEY` reads the value from standard input (so
  the value never appears in the process argument list or the shell history),
  and `nagarectl secret list notes` afterwards prints `API_KEY` but never its
  value.
- Every mutating command accepts `--dry-run`, which prints the exact
  ConfigMap/Secret manifest that *would* be applied and touches no cluster — so
  the whole surface is demonstrable on a laptop with no cluster at all.

A concrete end-to-end session (against a real cluster) looks like this:

```console
$ nagarectl env set notes LOG_LEVEL info
Set LOG_LEVEL in runtime env for notes.
$ nagarectl env set notes REGION us-west1
Set REGION in runtime env for notes.
$ nagarectl env list notes
  SCOPE    KEY        VALUE
  runtime  LOG_LEVEL  info
  runtime  REGION     us-west1
$ nagarectl env delete notes REGION
Deleted REGION from runtime env for notes.
$ printf 'postgres://u:p@h/db' | nagarectl secret set notes DATABASE_URL
Set DATABASE_URL in runtime secret for notes.
$ nagarectl secret list notes
DATABASE_URL
$ nagarectl env sync notes --file .env.production --reconcile-exact
Synced 4 key(s) into runtime env for notes (reconcile-exact).
```

The whole feature is a thin command-line surface over a pure, already-tested
library (EP-24's `Nagare.Env.Store`, see Context). This plan adds *no* new
cluster logic; it adds option parsers, a small dotenv parser, and the glue that
turns parsed flags into calls to that library.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Confirmed hard dependency EP-24 is merged: `Nagare.Env.Store` exists and
      exports the store API; `nagare-dsl` exports `EnvScope (..)`/`scopeToken`. (2026-06-09)
- [x] M1: Created `cli/nagarectl/src/Nagare/Env/Dotenv.hs` with
      `parseDotenv :: Text -> Either Text (Map Text Text)`. (2026-06-09)
- [x] M1: Registered `Nagare.Env.Dotenv` in `cli/nagarectl/nagarectl.cabal`
      (`exposed-modules` of the `library` stanza). (2026-06-09)
- [x] M1: Added a tasty test group `Nagare.Env.Dotenv` (9 cases) covering
      comments, blanks, `export`, quoting, multiline, and malformed lines. (2026-06-09)
- [x] M1: `cd cli/nagarectl && cabal test` is green (73 tests). (2026-06-09)
- [x] M2: Added the `Env` command and its subparsers (`list`/`set`/`delete`/`sync`)
      to `cli/nagarectl/app/Main.hs`; implemented `runEnv` handlers; all mutating
      handlers honor `--dry-run`. Used `configFileOpt` (`-f/--config`) so `sync`'s
      dotenv uses `--file`. (2026-06-09)
- [x] M2: Added the pure helper `reconcileModeFrom :: Bool -> ReconcileMode`;
      its selection behavior is unit-tested via `reconcile` in the
      `Nagare.Env reconcile mode` group (2 cases). (2026-06-09)
- [x] M2: `cabal build` green; `env set`/`sync --dry-run` produce the expected
      ConfigMap manifests with the IP2 name (verified, no cluster). (2026-06-09)
- [x] M3: Added the `Secret` command and its subparsers (`set`/`list`/`delete`)
      to `cli/nagarectl/app/Main.hs`; `secret set` reads the value from stdin
      (TTY: no-echo prompt; pipe: whole stdin minus one trailing newline);
      `secret list` prints key names only. (2026-06-09)
- [x] M3: `cabal build` green; `printf 'topsecret' | secret set --dry-run`
      prints a Secret whose `data.API_KEY` is `dG9wc2VjcmV0` (base64 of
      `topsecret`), proving the value came from stdin. (2026-06-09)
- [x] Manual live-cluster check **skipped** — optional; the whole surface is
      demonstrated cluster-free via `--dry-run`. EP-28 exercises it end to end
      against `tan-nb-exp`. (2026-06-09)
- [x] Filled in Outcomes & Retrospective. (2026-06-09)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: `APP` is resolved to a `(name, namespace)` pair by **loading the
  app's typed config** (`nagare/Config.hs` by default, overridable with
  `-f/--file`), exactly as the existing `site` subcommands already do, rather
  than taking `APP` as a literal name plus a `--namespace` flag.
  Rationale: the managed ConfigMap/Secret names are derived from `(name, scope)`
  by EP-23's `managedConfigMapName`/`managedSecretName`, and the *running
  Service* references those same names via `envFrom`. If the CLI derived names
  from a hand-typed `APP`, an operator typo would write a store the Service never
  reads — a silent, confusing no-op. Deriving the identity from the same config
  that produced the Service guarantees the names match. The `site releases`,
  `site rollback`, and `site preview` commands in `cli/nagarectl/app/Main.hs`
  already establish this "load config → take `(name, namespace)`" pattern
  (`siteIdentityOrDie`, `siteConfigIdentity`), so `env`/`secret` reuse it for
  consistency. The positional `APP` argument is retained in the surface for
  readability and forward-compatibility (a future name-only path can fill it),
  but in this plan it is informational: the identity comes from the loaded
  config. To keep the surface honest, when both are present the loaded config's
  name is authoritative and a mismatch with the positional `APP` is a hard error
  (`dieT`), so the operator is told rather than silently surprised.
  Date: 2026-06-09.

- Decision: `secret set APP KEY` reads the secret *value* from **standard input**
  (stdin), never from a command-line argument. Rationale: command-line arguments
  are visible to every process on the host (`ps`, `/proc`) and are recorded in
  shell history; a secret passed as `argv` leaks. Reading from stdin
  (`printf '%s' "$value" | nagarectl secret set notes API_KEY`, or interactively
  with a no-echo prompt when stdin is a TTY) keeps the value out of both. This
  mirrors how `kubectl create secret --from-file=-` and `docker login
  --password-stdin` handle the same problem.
  Date: 2026-06-09.

- Decision: `env sync` defaults to **Merge** (keep existing keys not present in
  the file); `--reconcile-exact` is the opt-in destructive mode (the store
  becomes exactly the file). `env set` is always a single-key Merge; `env delete`
  removes one key by reading the store, deleting the key, and writing the
  remaining set back. Rationale: this matches EP-24's stated intent that Merge is
  the conservative default and only an explicit reconcile-exact should delete an
  operator's other variables (EP-24 Decision Log). `--merge` is accepted
  explicitly for symmetry and self-documentation; `--merge` and
  `--reconcile-exact` are mutually exclusive.
  Date: 2026-06-09.

- Decision: `--dry-run` on a mutating command prints the **rendered
  ConfigMap/Secret manifest** that would be applied (via EP-24's
  `renderEnvConfigMap`/`renderEnvSecret`) and applies nothing, mirroring the
  `nagarectl deploy --dry-run` ethos (`runDeploy` in
  `cli/nagarectl/app/Main.hs`, which prints the rendered Service and exits
  without touching Docker or the cluster). Rationale: it makes the entire surface
  reproducible and testable without a cluster, and it lets an operator review
  exactly what will change before it changes. For a Secret, the dry-run prints
  the manifest with base64-encoded values (the real wire format); this is not a
  secrecy regression because base64 is an encoding, not encryption, and the
  operator already holds the plaintext they just typed.
  Date: 2026-06-09.

- Decision: The dotenv parser lives in its own library module
  `cli/nagarectl/src/Nagare/Env/Dotenv.hs` exposing
  `parseDotenv :: Text -> Either Text (Map Text Text)`, rather than inline in
  `Main.hs`. Rationale: parsing has edge cases (comments, blank lines, quoting,
  multiline quoted values, malformed lines) that deserve unit tests, and `Main.hs`
  is not in the test suite's module graph (the executable's `Main` is not
  importable). A library module is testable from `Spec.hs` directly.
  Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Outcome (2026-06-09): complete, all three milestones.** `nagarectl` now has the
full `env list|set|delete|sync` and `secret set|list|delete` surface, a tested
dotenv parser, and the identity/scope/dry-run glue, all as a thin layer over EP-24's
`Nagare.Env.Store`. The command grammar committed in Interfaces and Dependencies is
implemented verbatim. Verified cluster-free via `--dry-run`:
- `env set hello LOG_LEVEL info --dry-run` →
  `{"data":{"LOG_LEVEL":"info"},...,"metadata":{"name":"nagare-env-hello-runtime",...}}`.
- `env sync hello --file demo.env --dry-run` → `data` `{"A":"1","B":"2","C":"x y"}`
  (comment ignored, quoted `x y` preserved).
- `printf 'topsecret' | secret set hello API_KEY --dry-run` → a Secret typed
  `Opaque` whose `data.API_KEY` is `dG9wc2VjcmV0` (base64 of `topsecret`), proving
  the value flowed from stdin, never argv.
- A positional `APP` that disagrees with the loaded config's name is a hard error.

**Against the purpose:** the day-2 operation now exists — an operator changes a
running app's environment by writing the managed ConfigMap/Secret the Service
already references, with no Haskell edit and no image rebuild.

**Notes / lessons:**
- The `--file` collision (config file vs dotenv file) was resolved by giving the
  `env`/`secret` config option `-f/--config` (via a new `configFileOpt`), freeing
  `--file` for `env sync`'s dotenv argument exactly as the roadmap spells it.
- `containers` had to be added to the **executable** stanza's `build-depends` (it was
  only in the library and test stanzas) because `Main.hs` now uses `Data.Map`.
- `appIdentityOrDie` tries `loadDeployment` first and falls back to `loadSite` on
  `UnexpectedKind`, so `env`/`secret` work for plain apps, static sites, and server
  sites alike.
- `secret set` reads stdin (no-echo TTY prompt or piped value minus one trailing
  newline); `secret list` prints only `Map.keys`, never values.
- The live-cluster check was skipped (optional); EP-28 covers end to end.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before
editing. It names every file by full path and defines every term of art.

### What `nagarectl` is and where its code lives

`nagarectl` is the Nagare deploy CLI: a Haskell program (GHC 9.12, built with
`cabal` through a nix flake) that loads a typed configuration file, renders
Kubernetes/Knative manifests, builds and pushes a container image, applies the
manifests, and prints the live URL. Its parts:

- The command-line entry point is `cli/nagarectl/app/Main.hs` (the executable's
  `Main` module). This is where every subcommand is parsed and dispatched. You
  will add the new `env` and `secret` subcommands here.
- The library lives under `cli/nagarectl/src/`. You will add one new file,
  `cli/nagarectl/src/Nagare/Env/Dotenv.hs`.
- The build configuration is `cli/nagarectl/nagarectl.cabal`. You will register
  the new module there.
- The test suite is the single file `cli/nagarectl/test/Spec.hs`, a `tasty`
  test program. You will add test groups there.

A sibling library, `nagare-dsl`, under `cli/nagare-dsl/`, holds the typed
deployment model, the smart constructors that validate config fields, and the
Knative manifest renderer. `nagarectl` already depends on it.

### How the CLI parses subcommands (the pattern you will copy)

`nagarectl` uses the `optparse-applicative` library. The idea: a single sum type
`Command` enumerates everything the CLI can be asked to do; a parser turns the
process arguments into a `Command` value; and `main` pattern-matches the
`Command` to a handler. The relevant excerpt of `cli/nagarectl/app/Main.hs` (the
`Command` type, around lines 116–125) is:

```haskell
-- | Everything @nagarectl@ can be asked to do.
data Command
  = Deploy DeployOpts
  | SiteDeploy SiteDeployOpts
  | SiteReleases SiteCommonOpts
  | SiteRollback SiteCommonOpts String
  | SitePreviewDeploy SiteDeployOpts String
  | SitePreviewList SiteCommonOpts
  | SitePreviewDelete SiteCommonOpts String
```

The top-level parser (`opts`, around lines 239–308) builds a *subparser* — a
parser that dispatches on the first word after `nagarectl`. The `site` word is
itself a subparser of further subcommands (`deploy`, `releases`, `rollback`,
`preview`), and `preview` is a subparser again. That nested structure is exactly
what you will mirror for `env` and `secret`. The shape is:

```haskell
opts :: ParserInfo Command
opts =
  info
    (commandParser <**> helper)
    ( fullDesc
        <> progDesc "nagarectl — deploy a typed Nagare app or static site to Knative"
    )
  where
    commandParser =
      subparser
        ( command "deploy" deployCmd
            <> command "site" siteCmd
        )
    siteCmd =
      info
        (siteSubparser <**> helper)
        (fullDesc <> progDesc "Static and full-stack site hosting")
    siteSubparser =
      subparser
        ( command "deploy" siteDeployCmd
            <> command "releases" siteReleasesCmd
            <> command "rollback" siteRollbackCmd
            <> command "preview" sitePreviewCmd
        )
```

In plain words: `subparser` takes one or more `command "<word>" <info>` entries
joined with `<>`; each `<info>` is built with `info (<parser> <**> helper)
(fullDesc <> progDesc "...")`; and the parser inside either produces a `Command`
constructor directly (a leaf command) or is itself another `subparser` (a
grouping word like `site` or `preview`). The `<**> helper` adds `--help` to each
level.

`main` then dispatches (around lines 313–322):

```haskell
main :: IO ()
main =
  execParser opts >>= \case
    Deploy dopts -> runDeploy dopts
    SiteDeploy sopts -> runSiteDeploy sopts
    SiteReleases copts -> runSiteReleases copts
    SiteRollback copts rid -> runSiteRollback copts (T.pack rid)
    SitePreviewDeploy sopts pname -> runPreviewDeploy sopts (T.pack pname)
    SitePreviewList copts -> runPreviewList copts
    SitePreviewDelete copts pname -> runPreviewDelete copts (T.pack pname)
```

You will add `Env EnvCommand` and `Secret SecretCommand` constructors, a
`command "env" envCmd` and `command "secret" secretCmd` to the top-level
`subparser`, and the corresponding handler dispatch arms.

### How a command flows end to end (the model handler)

`runDeploy` (around lines 324–357) is the template for a mutating handler with a
dry-run. Read it: it resolves options, loads the config (`Load.loadDeployment`),
and then branches on `dryRun` — in dry-run it prints the rendered manifests and
exits with no side effect; otherwise it builds, pushes, applies, waits, and
prints the URL.

```haskell
runDeploy :: DeployOpts -> IO ()
runDeploy dopts = do
  ...
  edep <- Load.loadDeployment (dopts ^. #file)
  dep <- case edep of
    Left err -> dieT (Load.renderLoadError err)
    Right d -> pure d
  ...
  if dopts ^. #dryRun
    then do
      BC.putStrLn "--- Knative Service manifest ---"
      BC.putStr svcBytes
      ...
    else do
      ...
      applyManifests (svcBytes : dmBytes)
      ...
```

Your `env`/`secret` handlers follow the same `if dryRun then print-manifest else
write-store` shape, but instead of building images they call EP-24's store
functions.

### Resolving `APP` to `(name, namespace)` — reuse the existing helpers

A managed env/secret store is named per app *and scope* (see below), and the
*running Service* references those exact names. To make the store the CLI writes
match the store the Service reads, the CLI must learn the app's
`(name, namespace)` from the same config that produced the Service — not from a
hand-typed string (see Decision Log). The existing `site` commands already do
this. In `cli/nagarectl/app/Main.hs`:

```haskell
-- | The (name, namespace) of either site kind.
siteConfigIdentity :: Load.SiteConfig -> (Text, Text)
siteConfigIdentity (Load.SiteStatic s) =
  (siteNameText (s ^. #name), namespaceText (s ^. #namespace))
siteConfigIdentity (Load.SiteServer s) =
  (siteNameText (s ^. #name), namespaceText (s ^. #namespace))

-- | Load a site of either kind and return its (name, namespace).
siteIdentityOrDie :: FilePath -> IO (Text, Text)
siteIdentityOrDie file = do
  esite <- Load.loadSite file
  case esite of
    Left err -> dieT (Load.renderLoadError err)
    Right sc -> pure (siteConfigIdentity sc)
```

The config loader `Nagare.Dsl.Load` (in
`cli/nagare-dsl/src/Nagare/Dsl/Load.hs`) compiles-and-runs a `nagare/Config.hs`
with `runghc`, captures the JSON it prints, and decodes it into a validated
value. `loadDeployment` returns a `Deployment` (an ordinary app);
`loadSite` returns a `SiteConfig` (a static or server site); `loadStaticSite`/
`loadServerSite` are the kind-specific loaders. Each carries a `name` and a
`namespace` field. The text accessors are `serviceNameText`/`namespaceText`
(for a `Deployment`, from `Nagare.Dsl.Types`) and `siteNameText`/`namespaceText`
(for a site, from `Nagare.Dsl.Static.Types`/`Nagare.Dsl.Types`). All are already
imported in `Main.hs`.

Because an app might be deployed via `nagarectl deploy` (a `Deployment`) *or*
`nagarectl site deploy` (a `StaticSite`/`ServerSite`), the env/secret commands
must resolve identity for **any** of those kinds. The cleanest way is to try
`Load.loadDeployment` first and, on an `UnexpectedKind` error (the config is a
site, not a plain `Deployment`), fall back to `Load.loadSite`. Implement one
helper:

```haskell
-- | Resolve (name, namespace) from a config of any kind: a plain Deployment,
-- a StaticSite, or a ServerSite. Tries the Deployment loader first; on an
-- "UnexpectedKind" (the config is a site), falls back to the site loader.
appIdentityOrDie :: FilePath -> IO (Text, Text)
appIdentityOrDie file = do
  edep <- Load.loadDeployment file
  case edep of
    Right dep ->
      pure (serviceNameText (dep ^. #name), namespaceText (dep ^. #namespace))
    Left (Load.UnexpectedKind _ _) -> siteIdentityOrDie file
    Left err -> dieT (Load.renderLoadError err)
```

(`Load.UnexpectedKind` is the constructor `loadDeployment` returns when the
config emitted a `StaticSite`/`ServerSite` instead of a `Deployment`; it is
exported from `Nagare.Dsl.Load`. `siteIdentityOrDie` already exists in `Main.hs`.)

### Scopes and the managed-resource names (from EP-23 — do not re-derive)

A **scope** answers "*when* does this variable apply?" — at runtime (in the
running container), at build time (during the image build), or only in preview
deployments. The plan `docs/plans/23-scoped-env-model-and-scoped-knative-renderer.md`
(EP-23) defines the scope type and the naming helpers and exports them from the
`nagare-dsl` library. Their exact contract (which this plan consumes verbatim and
must not redesign):

```haskell
-- Exported by nagare-dsl (EP-23). Import; do not redefine.
data EnvScope = Runtime | Build | Preview
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

scopeToken           :: EnvScope -> Text          -- "runtime" / "build" / "preview"
managedConfigMapName :: Text -> EnvScope -> Text  -- "nagare-env-<app>-<scope>"
managedSecretName    :: Text -> EnvScope -> Text  -- "nagare-secret-<app>-<scope>"
```

For example, `managedConfigMapName "notes" Runtime == "nagare-env-notes-runtime"`
and `managedSecretName "notes" Runtime == "nagare-secret-notes-runtime"`. Per the
MasterPlan's Integration Points IP2 and IP3, every rendered Knative Service
references the *Runtime*-scoped ConfigMap and Secret in its `envFrom` list with
`optional: true`. That is why writing the store under those names is all it takes
to change a running app's environment, and why the CLI must use these helpers
(through EP-24, which already imports them) rather than format the names by hand.

### The store this CLI sits on (from EP-24 — consume verbatim)

The plan `docs/plans/24-per-app-secret-and-configmap-store-with-reconcile-modes.md`
(EP-24) delivers `cli/nagarectl/src/Nagare/Env/Store.hs`: a tested library that
reads, reconciles, and writes the per-app, per-scope key/value store. This plan
hard-depends on EP-24 and consumes its public contract exactly as given (do not
redesign it):

```haskell
-- From Nagare.Env.Store (EP-24, MasterPlan IP4):
data ReconcileMode = Merge | ReconcileExact

-- Merge: union, incoming wins on collision, existing-only keys kept.
-- ReconcileExact: incoming becomes the whole store; existing-only keys dropped.
reconcile :: ReconcileMode -> Map Text Text -> Map Text Text -> Map Text Text

-- Pure render to apply-able JSON manifest bytes. Args: app, namespace, scope, values.
renderEnvConfigMap :: Text -> Text -> EnvScope -> Map Text Text -> ByteString
renderEnvSecret    :: Text -> Text -> EnvScope -> Map Text Text -> ByteString

-- Thin kubectl IO. Missing resource => Right empty map. Args: app, namespace, scope[, values].
readEnvStore     :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))
readSecretStore  :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))
writeEnvStore    :: Text -> Text -> EnvScope -> Map Text Text -> IO ()
writeSecretStore :: Text -> Text -> EnvScope -> Map Text Text -> IO ()
```

The whole of this plan's IO is calls to these eight functions plus the two render
functions for `--dry-run`. The `Text` arguments are the app name and the
Kubernetes namespace (the `(name, namespace)` pair resolved above).

### What "dotenv" means

A **dotenv file** (conventionally named `.env`, `.env.production`, etc.) is a
plain-text file that lists environment variables one per line in `KEY=VALUE`
form. It is a near-universal convention for bulk-importing configuration. The
small parser this plan adds accepts the common subset:

- Each non-blank, non-comment line is `KEY=VALUE`.
- Blank lines (only whitespace) are ignored.
- Lines whose first non-whitespace character is `#` are comments and are ignored.
- The `KEY` is the text up to the first `=`, trimmed of surrounding whitespace. A
  leading `export ` (the shell idiom `export KEY=VALUE`) is stripped. A key must
  be non-empty and contain no whitespace or `=`.
- The `VALUE` is everything after the first `=`. If, after trimming surrounding
  whitespace, it is wrapped in matching single or double quotes, the quotes are
  stripped and the inner text is taken literally (so a `#` inside quotes is part
  of the value, not a comment). A quoted value may span multiple physical lines:
  if an opening quote is not closed on the same line, subsequent lines are
  appended (with their newlines) until the closing quote is found.
- A line with no `=` (and that is not blank/comment) is a hard error
  (`Left`), so a typo is reported rather than silently dropped.

The parser's signature is `parseDotenv :: Text -> Either Text (Map Text Text)`.
It is deliberately small and does *not* implement shell variable interpolation
(`${OTHER}`), escape sequences inside double quotes, or `.env` precedence rules —
those are out of scope and the Haddock says so.


## Plan of Work

The work splits into three independently verifiable milestones. M1 is a pure,
unit-tested dotenv parser with no CLI wiring. M2 adds the `env` subcommands and
their `--dry-run` rendering (demonstrable with no cluster). M3 adds the `secret`
subcommands including stdin reading. Each milestone ends green on
`cd cli/nagarectl && cabal test` (M1) or `cabal build` plus a `--dry-run`
demonstration (M2, M3).

Before any milestone, confirm the hard dependency: EP-24's
`cli/nagarectl/src/Nagare/Env/Store.hs` must exist and export the eight
functions and `ReconcileMode` listed in Context, and `nagare-dsl` must export
`EnvScope (..)`. Verify with the grep in Concrete Steps Step 0. If it is not
present, stop and coordinate (Interfaces and Dependencies).

### Milestone 1 — The dotenv parser (pure, unit-tested)

**Scope.** Create `cli/nagarectl/src/Nagare/Env/Dotenv.hs` exposing
`parseDotenv :: Text -> Either Text (Map Text Text)`, register it in the cabal
`library` stanza, and add a tasty test group. No CLI wiring yet.

**What will exist that did not before.** A tested function that turns the text of
a `.env` file into a `Map Text Text` (or a `Left` error for a malformed line),
honoring blanks, `#` comments, `export ` prefixes, single/double quotes, and
multiline quoted values.

**Implementation.** In `cli/nagarectl/src/Nagare/Env/Dotenv.hs`:

```haskell
{-# LANGUAGE PackageImports #-}

-- | A minimal dotenv (@.env@) parser for @nagarectl env sync@ (EP-25).
--
-- Accepts @KEY=VALUE@ per line. Ignores blank lines and @#@ comments. Strips an
-- optional leading @export @. Trims surrounding whitespace around the key and
-- around the (unquoted) value. If the value is wrapped in matching single or
-- double quotes, the quotes are stripped and the inner text is taken literally
-- (a @#@ inside quotes is part of the value). A quoted value may span multiple
-- physical lines: lines are joined (with their newlines) until the closing quote.
-- A non-blank, non-comment line with no @=@ is a 'Left' error (never silently
-- dropped). Shell interpolation (@${X}@) and escape sequences are NOT supported.
module Nagare.Env.Dotenv
  ( parseDotenv
  ) where

import Nagare.Dsl.Prelude

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text qualified as T

parseDotenv :: Text -> Either Text (Map Text Text)
parseDotenv = fmap Map.fromList . go . T.lines
  where
    go :: [Text] -> Either Text [(Text, Text)]
    go [] = Right []
    go (line : rest)
      | isBlankOrComment line = go rest
      | otherwise = do
          (k, v, rest') <- parseEntry line rest
          ((k, v) :) <$> go rest'
```

Write the helpers:

- `isBlankOrComment line` is `True` when `T.strip line` is empty or begins with
  `#`.
- `parseEntry line rest` splits `line` on the first `=` (use `T.breakOn "="`; an
  empty remainder means no `=`, which is `Left ("malformed line (no '='): " <>
  line)`). The raw key is the part before `=`, run through `stripExport . T.strip`,
  and validated: non-empty and no whitespace or `=` (else `Left`). The raw value
  is the part after the first `=` (`T.drop 1` of the remainder).
- For the value, call `parseValue rawValue rest`. If `T.strip rawValue` starts
  with `'` or `"` and the same quote closes on the same line, return the inner
  text and `rest` unchanged. If the opening quote is not closed on the line,
  consume lines from `rest`, appending each with a leading newline, until a line
  containing the closing quote is found; the value is everything between the
  quotes (the trailing text after the closing quote on the final line is ignored,
  matching dotenv convention) and the returned remaining lines are what follows.
  If `T.strip rawValue` is not quoted, the value is `T.strip rawValue` and `rest`
  is unchanged.
- `stripExport t = fromMaybe t (T.stripPrefix "export " t)`.

Keep the implementation total: every `Left` carries a one-line message naming the
offending line.

**Register the module.** In `cli/nagarectl/nagarectl.cabal`, add
`Nagare.Env.Dotenv` to the `library` stanza's `exposed-modules` list (it is a
small public helper; exposing it lets `Spec.hs` import it directly). The
`containers` package (for `Data.Map`) and `text` are already dependencies of the
library stanza? — `text` is; add `containers,` to the `library` stanza's
`build-depends` if it is not already there (the test-suite already lists it; the
library stanza must list it too for this module).

**Tests.** In `cli/nagarectl/test/Spec.hs`, add `import Nagare.Env.Dotenv`, add
`testGroup "Nagare.Env.Dotenv" dotenvTests` to the top-level list, and define:

```haskell
dotenvTests :: [TestTree]
dotenvTests =
  [ testCase "parses KEY=VALUE lines" $
      parseDotenv "A=1\nB=2"
        @?= Right (Map.fromList [("A", "1"), ("B", "2")])
  , testCase "ignores blank lines and # comments" $
      parseDotenv "# a comment\n\nA=1\n   \n# another\nB=2"
        @?= Right (Map.fromList [("A", "1"), ("B", "2")])
  , testCase "strips a leading export" $
      parseDotenv "export A=1"
        @?= Right (Map.fromList [("A", "1")])
  , testCase "trims whitespace around key and unquoted value" $
      parseDotenv "  A =  hello "
        @?= Right (Map.fromList [("A", "hello")])
  , testCase "double-quoted value keeps inner # and spaces" $
      parseDotenv "A=\"a # b c\""
        @?= Right (Map.fromList [("A", "a # b c")])
  , testCase "single-quoted value is literal" $
      parseDotenv "A='x y'"
        @?= Right (Map.fromList [("A", "x y")])
  , testCase "multiline quoted value spans lines" $
      parseDotenv "A=\"line1\nline2\"\nB=2"
        @?= Right (Map.fromList [("A", "line1\nline2"), ("B", "2")])
  , testCase "a line with no = is an error" $
      assertLeftText (parseDotenv "A=1\nNOEQUALS\nB=2")
  , testCase "an empty key is an error" $
      assertLeftText (parseDotenv "=value")
  ]
```

`assertLeftText` already exists in `Spec.hs`. `Map` is already imported there
(`import Data.Map qualified as Map`).

**Commands and acceptance.**

```bash
cd cli/nagarectl && cabal test
```

Acceptance: the `Nagare.Env.Dotenv` group is listed and every case is `OK`. These
tests fail before the module exists (compile error: module not found) and pass
after.

### Milestone 2 — The `env` subcommands (list / set / delete / sync)

**Scope.** Add the `env` command tree to `cli/nagarectl/app/Main.hs`: a top-level
`command "env" envCmd` whose subparser has `list`, `set`, `delete`, and `sync`.
Wire handlers that resolve `(name, namespace)` from the config, select scope(s)
from `--runtime/--build/--preview` (default `--runtime`), and call EP-24's store
functions. Every mutating handler honors `--dry-run` by printing the rendered
ConfigMap manifest(s) from `renderEnvConfigMap`. Add a pure
`reconcileModeFrom`-style helper and unit-test it.

**What will exist that did not before.** `nagarectl env list APP`,
`nagarectl env set APP KEY VALUE`, `nagarectl env delete APP KEY`, and
`nagarectl env sync APP --file FILE [scopes] [mode]`, all working in `--dry-run`
with no cluster, and against a live cluster otherwise.

**New types and parsers in `Main.hs`.** Add to the `Command` sum type:

```haskell
  | Env EnvCommand
  | Secret SecretCommand          -- (added in M3)
```

Define the `env` command tree:

```haskell
-- | Options shared by every @env@/@secret@ subcommand: enough to load the
-- config and resolve (name, namespace), plus the positional APP for readability.
data StoreCommonOpts = StoreCommonOpts
  { app :: !String            -- ^ positional APP (informational; identity comes from the config)
  , file :: !FilePath         -- ^ -f/--file, default nagare/Config.hs
  , ghcEnv :: !(Maybe FilePath)
  }
  deriving stock (Generic, Show)

-- | Which scope store(s) an operation targets. At least one is always selected;
-- when none of --runtime/--build/--preview is given, Runtime is the default.
data ScopeSelection = ScopeSelection
  { runtime :: !Bool
  , build :: !Bool
  , preview :: !Bool
  }
  deriving stock (Generic, Show)

data EnvCommand
  = EnvList StoreCommonOpts Bool             -- ^ Bool = --all (show all three scopes)
  | EnvSet StoreCommonOpts ScopeSelection Bool String String  -- ^ dryRun, KEY, VALUE
  | EnvDelete StoreCommonOpts ScopeSelection Bool String      -- ^ dryRun, KEY
  | EnvSync StoreCommonOpts ScopeSelection Bool Bool FilePath -- ^ dryRun, reconcileExact, --file
```

Parsers (reuse `fileOpt defaultConfigFile`, `ghcEnvOpt`, `dryRunOpt` already in
`Main.hs`):

```haskell
appArg :: Parser String
appArg = strArgument (metavar "APP" <> help "App whose env/secret store to manage")

storeCommonOptsParser :: Parser StoreCommonOpts
storeCommonOptsParser =
  StoreCommonOpts <$> appArg <*> fileOpt defaultConfigFile <*> ghcEnvOpt

scopeSelectionParser :: Parser ScopeSelection
scopeSelectionParser =
  ScopeSelection
    <$> switch (long "runtime" <> help "Target the runtime scope (default if no scope flag is given)")
    <*> switch (long "build" <> help "Target the build scope")
    <*> switch (long "preview" <> help "Target the preview scope")

-- | Resolve the selected scopes; with none chosen, default to [Runtime].
selectedScopes :: ScopeSelection -> [EnvScope]
selectedScopes (ScopeSelection r b p)
  | not r && not b && not p = [Runtime]
  | otherwise = [Runtime | r] <> [Build | b] <> [Preview | p]

reconcileModeParser :: Parser Bool   -- ^ True => ReconcileExact, False => Merge
reconcileModeParser =
  flag' True (long "reconcile-exact" <> help "Make the store exactly the file (drop keys not present)")
    <|> flag' False (long "merge" <> help "Keep existing keys not in the file (default)")
    <|> pure False
```

(`flag'`/`<|>`/`pure False` makes `--merge` and `--reconcile-exact` mutually
exclusive with a sane default of `False` = Merge. `EnvScope (..)` is imported
from `Nagare.Dsl.Types`, available through `nagare-dsl`.)

The pure helper that M2 unit-tests:

```haskell
-- | The reconcile mode for a sync: --reconcile-exact => ReconcileExact, else Merge.
reconcileModeFrom :: Bool -> ReconcileMode
reconcileModeFrom True = ReconcileExact
reconcileModeFrom False = Merge
```

(Imported `ReconcileMode (..)`, `reconcile`, the render and store functions come
from `Nagare.Env.Store`.)

Wire the subparser into `opts` (add to the top-level `subparser`):

```haskell
        ( command "deploy" deployCmd
            <> command "site" siteCmd
            <> command "env" envCmd
            <> command "secret" secretCmd     -- (M3)
        )
```

and define `envCmd`:

```haskell
    envCmd =
      info (envSubparser <**> helper)
        (fullDesc <> progDesc "Manage an app's environment variables (managed ConfigMap store)")
    envSubparser =
      subparser
        ( command "list"
            (info (EnvList <$> storeCommonOptsParser
                           <*> switch (long "all" <> help "Show all scopes, grouped")
                           <**> helper)
               (progDesc "List env keys/values for an app"))
            <> command "set"
            (info (EnvSet <$> storeCommonOptsParser <*> scopeSelectionParser <*> dryRunOpt
                          <*> strArgument (metavar "KEY") <*> strArgument (metavar "VALUE")
                          <**> helper)
               (progDesc "Set one env key (single-key merge)"))
            <> command "delete"
            (info (EnvDelete <$> storeCommonOptsParser <*> scopeSelectionParser <*> dryRunOpt
                             <*> strArgument (metavar "KEY") <**> helper)
               (progDesc "Delete one env key"))
            <> command "sync"
            (info (EnvSync <$> storeCommonOptsParser <*> scopeSelectionParser <*> dryRunOpt
                           <*> reconcileModeParser
                           <*> strOption (long "file" <> metavar "FILE" <> help "dotenv file to import")
                           <**> helper)
               (progDesc "Bulk-import a dotenv file into the env store"))
        )
```

(Note the `sync --file` is a *separate* option from the config `-f/--file`: the
config file is `storeCommonOptsParser`'s `-f`; the dotenv file is `sync`'s
`--file`. To avoid the collision, give the dotenv option only the long form
`--file` is already taken by the config file via `fileOpt`. Resolve by naming the
dotenv option `--env-file`/`--file` carefully: use `--file` for the dotenv on
`sync` and rename the config option there, *or* keep `fileOpt` as `-f/--file` for
the config and use `--file` long-only for the dotenv. Simplest: the config file
keeps `-f/--file` from `fileOpt`; the dotenv option uses the distinct long name
`--file` is ambiguous — therefore give the dotenv option the long name `--file`
**only on the sync command** by *not* using `fileOpt` there for the config and
instead reading the config file solely via `-f`. Implementation decision: keep
`storeCommonOptsParser` using `fileOpt` (`-f/--file`) for the config, and name
the dotenv option `--file` would clash; so name the dotenv option `--file` is the
roadmap spelling — to honor the roadmap (`env sync APP --file .env.production`)
while avoiding the clash, drop the long `--file` alias from the config option on
the `env`/`secret` commands by defining a config-file parser that offers only
`-f`/`--config`:

```haskell
configFileOpt :: Parser FilePath
configFileOpt =
  strOption (long "config" <> short 'f' <> metavar "FILE"
             <> value defaultConfigFile <> showDefault
             <> help "Path to the typed config file (its name/namespace identify the app)")
```

Use `configFileOpt` in `storeCommonOptsParser` instead of `fileOpt`, freeing
`--file` for `sync`'s dotenv argument exactly as the roadmap spells it.)

**Handlers.** Add dispatch arms in `main`:

```haskell
    Env ecmd -> runEnv ecmd
    Secret scmd -> runSecret scmd   -- (M3)
```

and implement:

```haskell
runEnv :: EnvCommand -> IO ()
runEnv = \case
  EnvList copts allScopes -> do
    provisionGhcEnv (copts ^. #ghcEnv)
    (name, ns) <- resolveAppOrDie copts
    let scopes = if allScopes then [minBound .. maxBound] else [Runtime]
    TIO.putStr (formatEnvTable scopes =<< undefined)   -- see note below
    ...
  EnvSet copts sel dry key val -> do
    provisionGhcEnv (copts ^. #ghcEnv)
    (name, ns) <- resolveAppOrDie copts
    forM_ (selectedScopes sel) $ \scope -> do
      existing <- orDie =<< readEnvStore name ns scope
      let desired = reconcile Merge existing (Map.singleton (T.pack key) (T.pack val))
      applyOrDryRunEnv dry name ns scope desired
    unless dry $ TIO.putStrLn ("Set " <> T.pack key <> " in env for " <> name <> ".")
  EnvDelete copts sel dry key -> do
    provisionGhcEnv (copts ^. #ghcEnv)
    (name, ns) <- resolveAppOrDie copts
    forM_ (selectedScopes sel) $ \scope -> do
      existing <- orDie =<< readEnvStore name ns scope
      let desired = reconcile ReconcileExact mempty (Map.delete (T.pack key) existing)
      applyOrDryRunEnv dry name ns scope desired
    unless dry $ TIO.putStrLn ("Deleted " <> T.pack key <> " from env for " <> name <> ".")
  EnvSync copts sel dry exact dotenvPath -> do
    provisionGhcEnv (copts ^. #ghcEnv)
    (name, ns) <- resolveAppOrDie copts
    raw <- TIO.readFile dotenvPath
    incoming <- orDie (parseDotenv raw)
    let mode = reconcileModeFrom exact
    forM_ (selectedScopes sel) $ \scope -> do
      existing <- orDie =<< readEnvStore name ns scope
      let desired = reconcile mode existing incoming
      applyOrDryRunEnv dry name ns scope desired
    unless dry $
      TIO.putStrLn ("Synced " <> tShow (Map.size incoming) <> " key(s) into env for " <> name <> ".")
```

with the supporting helpers:

```haskell
-- | Resolve (name, namespace) and reconcile it against the positional APP.
resolveAppOrDie :: StoreCommonOpts -> IO (Text, Text)
resolveAppOrDie copts = do
  (name, ns) <- appIdentityOrDie (copts ^. #file)
  let typed = T.pack (copts ^. #app)
  if typed /= name
    then dieT ("config names app '" <> name <> "' but the command names '" <> typed
                <> "'; they must match (the config's name is what the Service references)")
    else pure (name, ns)

-- | Print the rendered ConfigMap (dry-run) or write the store (otherwise).
applyOrDryRunEnv :: Bool -> Text -> Text -> EnvScope -> Map Text Text -> IO ()
applyOrDryRunEnv dry name ns scope desired
  | dry = do
      BC.putStrLn ("--- ConfigMap (" <> TE.encodeUtf8 (scopeToken scope) <> ") ---")
      BC.putStrLn (renderEnvConfigMap name ns scope desired)
  | otherwise = writeEnvStore name ns scope desired

tShow :: Show a => a -> Text
tShow = T.pack . show
```

For `EnvList`, read each requested scope and print an aligned table modeled on
`formatReleasesTable` in `cli/nagarectl/src/Nagare/Static/Release.hs`. Implement a
small formatter inline in `Main.hs` (it is presentation, not domain logic):

```haskell
runEnvListBody :: Text -> Text -> [EnvScope] -> IO ()
runEnvListBody name ns scopes = do
  rows <- fmap concat $ forM scopes $ \scope -> do
    m <- orDie =<< readEnvStore name ns scope
    pure [(scopeToken scope, k, v) | (k, v) <- Map.toAscList m]
  if null rows
    then TIO.putStrLn "(no env set)"
    else TIO.putStr (formatEnvRows rows)

formatEnvRows :: [(Text, Text, Text)] -> Text
formatEnvRows rows = T.unlines (header : map row rows)
  where
    header = "  SCOPE    KEY                 VALUE"
    row (s, k, v) = T.concat ["  ", pad 9 s, pad 20 k, v]
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "
```

(`EnvList` defaults to `[Runtime]`; `--all` lists `[Runtime, Build, Preview]`,
which is `[minBound .. maxBound]` for `EnvScope`.)

Add the imports at the top of `Main.hs`:

```haskell
import Control.Monad (unless)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Types (EnvScope (..), scopeToken, serviceNameText)
import Nagare.Env.Dotenv (parseDotenv)
import Nagare.Env.Store
  ( ReconcileMode (..)
  , reconcile
  , renderEnvConfigMap
  , renderEnvSecret
  , readEnvStore
  , readSecretStore
  , writeEnvStore
  , writeSecretStore
  )
```

(`forM_`, `forM`, `T`, `TIO`, `BC` are already imported. `serviceNameText` and
`namespaceText` are already imported via `Nagare.Dsl.Types`; add `scopeToken` and
`EnvScope` to that import list.)

**Test the pure mode helper.** In `Spec.hs` the `Main` executable module is not
importable, so test `reconcileModeFrom`'s *logic* by re-stating it as a tiny pure
function in the test (it is one line) **or**, preferably, prove the mode-selection
behavior through the store directly: add a test that `reconcile (reconcileMode)`
with a `--reconcile-exact`-shaped call drops a key and with `--merge` keeps it.
Because `reconcile` lives in `Nagare.Env.Store` (importable), add to `Spec.hs`:

```haskell
reconcileModeTests :: [TestTree]
reconcileModeTests =
  [ testCase "merge keeps a key absent from the incoming set" $
      reconcile Merge (Map.fromList [("KEEP", "1")]) (Map.fromList [("NEW", "2")])
        @?= Map.fromList [("KEEP", "1"), ("NEW", "2")]
  , testCase "reconcile-exact drops a key absent from the incoming set" $
      reconcile ReconcileExact (Map.fromList [("DROP", "1")]) (Map.fromList [("NEW", "2")])
        @?= Map.fromList [("NEW", "2")]
  ]
```

This is the behavior `env sync --merge` vs `--reconcile-exact` selects, proven
against the exact function the CLI calls. (If `reconcileModeFrom` is factored into
its own importable library module, test it directly instead; keeping it in
`Main.hs` and testing `reconcile` is sufficient and avoids over-modularizing.)

**Commands and acceptance.**

```bash
cd cli/nagarectl && cabal build
cabal test
```

Acceptance: `cabal build` is green; the new test groups pass; and the `--dry-run`
demonstrations in Concrete Steps produce the shown manifests with no cluster.

### Milestone 3 — The `secret` subcommands (set / list / delete)

**Scope.** Add the `secret` command tree to `cli/nagarectl/app/Main.hs`:
`command "secret" secretCmd` with `set`, `list`, `delete`. `secret set APP KEY`
reads the value from stdin (never argv). `secret list APP` prints key names only,
one per line. `secret delete APP KEY` removes one key. All use
`readSecretStore`/`writeSecretStore`; `set`/`delete` honor `--dry-run` by printing
the rendered Secret via `renderEnvSecret`.

**What will exist that did not before.** `nagarectl secret set APP KEY` (stdin),
`nagarectl secret list APP`, `nagarectl secret delete APP KEY`.

**Types and parsers.**

```haskell
data SecretCommand
  = SecretSet StoreCommonOpts ScopeSelection Bool String   -- ^ dryRun, KEY (value from stdin)
  | SecretList StoreCommonOpts Bool                        -- ^ Bool = --all
  | SecretDelete StoreCommonOpts ScopeSelection Bool String -- ^ dryRun, KEY
```

```haskell
    secretCmd =
      info (secretSubparser <**> helper)
        (fullDesc <> progDesc "Manage an app's secrets (managed Secret store)")
    secretSubparser =
      subparser
        ( command "set"
            (info (SecretSet <$> storeCommonOptsParser <*> scopeSelectionParser <*> dryRunOpt
                             <*> strArgument (metavar "KEY") <**> helper)
               (progDesc "Set one secret key; the value is read from stdin"))
            <> command "list"
            (info (SecretList <$> storeCommonOptsParser
                              <*> switch (long "all" <> help "Show all scopes")
                              <**> helper)
               (progDesc "List secret key names (never values)"))
            <> command "delete"
            (info (SecretDelete <$> storeCommonOptsParser <*> scopeSelectionParser <*> dryRunOpt
                                <*> strArgument (metavar "KEY") <**> helper)
               (progDesc "Delete one secret key"))
        )
```

**Handlers.**

```haskell
runSecret :: SecretCommand -> IO ()
runSecret = \case
  SecretSet copts sel dry key -> do
    provisionGhcEnv (copts ^. #ghcEnv)
    (name, ns) <- resolveAppOrDie copts
    val <- readSecretValue            -- from stdin; see below
    forM_ (selectedScopes sel) $ \scope -> do
      existing <- orDie =<< readSecretStore name ns scope
      let desired = reconcile Merge existing (Map.singleton (T.pack key) val)
      applyOrDryRunSecret dry name ns scope desired
    unless dry $ TIO.putStrLn ("Set " <> T.pack key <> " in secret for " <> name <> ".")
  SecretList copts allScopes -> do
    provisionGhcEnv (copts ^. #ghcEnv)
    (name, ns) <- resolveAppOrDie copts
    let scopes = if allScopes then [minBound .. maxBound] else [Runtime]
    keys <- fmap concat $ forM scopes $ \scope -> do
      m <- orDie =<< readSecretStore name ns scope
      pure (Map.keys m)
    if null keys then TIO.putStrLn "(no secrets set)" else mapM_ TIO.putStrLn keys
  SecretDelete copts sel dry key -> do
    provisionGhcEnv (copts ^. #ghcEnv)
    (name, ns) <- resolveAppOrDie copts
    forM_ (selectedScopes sel) $ \scope -> do
      existing <- orDie =<< readSecretStore name ns scope
      let desired = reconcile ReconcileExact mempty (Map.delete (T.pack key) existing)
      applyOrDryRunSecret dry name ns scope desired
    unless dry $ TIO.putStrLn ("Deleted " <> T.pack key <> " from secret for " <> name <> ".")

-- | Read one secret value. If stdin is a TTY, prompt with echo off; otherwise
-- read the whole of stdin and strip a single trailing newline (so a piped
-- `printf '%s' v` and an interactive line both work).
readSecretValue :: IO Text
readSecretValue = do
  isTty <- hIsTerminalDevice stdin
  if isTty
    then do
      TIO.hPutStr stderr "Value (input hidden): "
      hFlush stderr
      old <- hGetBuffering stdin
      bracket_ (hSetEcho stdin False) (hSetEcho stdin True >> TIO.hPutStrLn stderr "") TIO.getLine
    else do
      raw <- TIO.getContents
      pure (stripTrailingNewline raw)
  where
    stripTrailingNewline t = fromMaybe t (T.stripSuffix "\n" t)

applyOrDryRunSecret :: Bool -> Text -> Text -> EnvScope -> Map Text Text -> IO ()
applyOrDryRunSecret dry name ns scope desired
  | dry = do
      BC.putStrLn ("--- Secret (" <> TE.encodeUtf8 (scopeToken scope) <> ") ---")
      BC.putStrLn (renderEnvSecret name ns scope desired)
  | otherwise = writeSecretStore name ns scope desired
```

Add imports: `System.IO (stdin, hFlush, hSetEcho, hGetBuffering, hIsTerminalDevice)`
(in addition to the existing `import System.IO (stderr)`), and
`Control.Exception (bracket_)`. `directory` is already a dependency; `System.IO`
needs no extra package.

**Note on `secret list` not leaking values.** `SecretList` reads the store and
prints `Map.keys` only — the values are never rendered to stdout. The dry-run of
`set`/`delete` *does* print base64'd values (the manifest), which is acceptable
per the Decision Log (the operator already holds the plaintext).

**Commands and acceptance.**

```bash
cd cli/nagarectl && cabal build
printf 'topsecret' | cabal run nagarectl -- secret set hello API_KEY --dry-run -f cluster/examples/hello-knative-service/nagare/Config.hs
```

Acceptance: `cabal build` is green; the piped `secret set --dry-run` prints a
`Secret` manifest whose `data.API_KEY` is `dG9wc2VjcmV0` (base64 of `topsecret`),
proving the value came from stdin; `secret list` prints only key names.


## Concrete Steps

Run everything from the repository root unless a step says otherwise. The
repository root is the directory containing `cli/`, `docs/`, and `CLAUDE.md`. The
example config used below, `cluster/examples/hello-knative-service/nagare/Config.hs`,
names the app `hello` in namespace `personal`.

### Step 0 — Confirm the EP-24 hard dependency

```bash
grep -rn "module Nagare.Env.Store\|^reconcile ::\|readEnvStore ::\|writeSecretStore ::" cli/nagarectl/src/Nagare/Env/Store.hs
grep -rn "data EnvScope\|managedConfigMapName\|scopeToken" cli/nagare-dsl/src
```

Expected: the first grep shows `Nagare.Env.Store` with `reconcile`, `readEnvStore`,
and `writeSecretStore`; the second shows `data EnvScope = Runtime | Build |
Preview` and the name/token helpers in `nagare-dsl`. No output from the first
grep means EP-24 is not merged — stop and coordinate (Interfaces and
Dependencies).

### Step 1 — M1: create and register the dotenv module

Create `cli/nagarectl/src/Nagare/Env/Dotenv.hs` per Milestone 1. Edit
`cli/nagarectl/nagarectl.cabal`: add `Nagare.Env.Dotenv` to the `library`
stanza's `exposed-modules`, and ensure `containers,` is in the `library` stanza's
`build-depends` (the test-suite already has it).

```bash
cd cli/nagarectl && cabal build
```

Expected: builds clean (the module compiles; nothing uses it yet).

### Step 2 — M1: add and run the dotenv tests

Edit `cli/nagarectl/test/Spec.hs` per Milestone 1, then:

```bash
cd cli/nagarectl && cabal test
```

Expected (abridged — existing groups still run):

```text
nagarectl
  ...
  Nagare.Env.Dotenv
    parses KEY=VALUE lines:                       OK
    ignores blank lines and # comments:           OK
    strips a leading export:                      OK
    trims whitespace around key and unquoted value: OK
    double-quoted value keeps inner # and spaces: OK
    single-quoted value is literal:               OK
    multiline quoted value spans lines:           OK
    a line with no = is an error:                 OK
    an empty key is an error:                      OK

All N tests passed
```

### Step 3 — M2: add the `env` command tree and handlers

Edit `cli/nagarectl/app/Main.hs` per Milestone 2 (new `Command` constructors,
parsers, `envCmd`/`envSubparser`, handlers, imports, and the `configFileOpt` that
frees `--file` for `sync`). Add the `reconcileModeTests` group to `Spec.hs`.

```bash
cd cli/nagarectl && cabal build && cabal test
```

Expected: green build; `reconcileModeTests` pass.

### Step 4 — M2: demonstrate `env` with `--dry-run` (no cluster)

The dry-run path of `set`/`delete`/`sync` reads the *existing* store from the
cluster before reconciling. To make the demonstration fully cluster-free, note
that `readEnvStore` treats a missing/unreachable resource as an empty map only on
a non-zero `kubectl` exit; with no cluster `kubectl` exits non-zero, so the
existing store reads as empty and the dry-run still renders. Run:

```bash
cd cli/nagarectl
CONFIG=cluster/examples/hello-knative-service/nagare/Config.hs
cabal run nagarectl -- env set hello LOG_LEVEL info --dry-run -f ../../$CONFIG
```

Expected output (the JSON is one line; shown wrapped):

```text
--- ConfigMap (runtime) ---
{"apiVersion":"v1","data":{"LOG_LEVEL":"info"},"kind":"ConfigMap",
 "metadata":{"name":"nagare-env-hello-runtime","namespace":"personal"}}
Set LOG_LEVEL in env for hello.
```

(The trailing "Set ..." line is suppressed under `--dry-run` in the handler shown
above via `unless dry`; if you prefer a confirmation under dry-run too, it is
cosmetic. The manifest is the load-bearing output.)

A dotenv sync dry-run:

```bash
printf 'A=1\nB=2\n# comment\nC="x y"\n' > /tmp/demo.env
cabal run nagarectl -- env sync hello --file /tmp/demo.env --dry-run -f ../../$CONFIG
```

Expected: a ConfigMap manifest whose `data` is `{"A":"1","B":"2","C":"x y"}`.

### Step 5 — M3: add the `secret` command tree and handlers

Edit `cli/nagarectl/app/Main.hs` per Milestone 3.

```bash
cd cli/nagarectl && cabal build
CONFIG=cluster/examples/hello-knative-service/nagare/Config.hs
printf 'topsecret' | cabal run nagarectl -- secret set hello API_KEY --dry-run -f ../../$CONFIG
```

Expected:

```text
--- Secret (runtime) ---
{"apiVersion":"v1","data":{"API_KEY":"dG9wc2VjcmV0"},"kind":"Secret",
 "metadata":{"name":"nagare-secret-hello-runtime","namespace":"personal"},
 "type":"Opaque"}
```

`dG9wc2VjcmV0` is base64 of `topsecret`; confirm with
`printf 'dG9wc2VjcmV0' | base64 -d` → `topsecret`. The value came from the piped
stdin, never from `argv`.

### Step 6 — Live check (optional, GCP `tan-nb-exp` / `us-west1`)

With a kube context pointed at the Nagare cluster (per `CLAUDE.md`, only
`tan-nb-exp`, region `us-west1`):

```bash
cd cli/nagarectl
CONFIG=cluster/examples/hello-knative-service/nagare/Config.hs
cabal run nagarectl -- env set hello LOG_LEVEL info -f ../../$CONFIG
cabal run nagarectl -- env set hello REGION us-west1 -f ../../$CONFIG
cabal run nagarectl -- env list hello -f ../../$CONFIG
printf 'postgres://u:p@h/db' | cabal run nagarectl -- secret set hello DATABASE_URL -f ../../$CONFIG
cabal run nagarectl -- secret list hello -f ../../$CONFIG
kubectl get configmap nagare-env-hello-runtime -n personal -o jsonpath='{.data}'
kubectl get secret nagare-secret-hello-runtime -n personal -o jsonpath='{.data.DATABASE_URL}' | base64 -d
```

Expected: `env list` shows `LOG_LEVEL=info` and `REGION=us-west1`; `secret list`
shows `DATABASE_URL` (not its value); the `kubectl` ConfigMap query prints
`{"LOG_LEVEL":"info","REGION":"us-west1"}`; the decoded Secret value prints
`postgres://u:p@h/db`. Clean up with
`kubectl delete configmap nagare-env-hello-runtime -n personal` and
`kubectl delete secret nagare-secret-hello-runtime -n personal`.


## Validation and Acceptance

Acceptance is phrased as behavior with concrete inputs and outputs.

**Dotenv parsing (M1, unit tests).** `parseDotenv "A=1\nB=2"` is
`Right {A:1, B:2}`. Comments and blanks are ignored. `export A=1` yields
`{A:1}`. A double-quoted value `A="a # b c"` keeps the inner `#` and spaces. A
multiline quoted value `A="line1\nline2"` spans lines. A line with no `=` and an
empty key are each `Left`. These fail before `Nagare.Env.Dotenv` exists (module
not found) and pass after; run `cd cli/nagarectl && cabal test`.

**Reconcile-mode selection (M2, unit tests).** `reconcile Merge {KEEP:1} {NEW:2}`
is `{KEEP:1, NEW:2}` (existing-only key kept); `reconcile ReconcileExact {DROP:1}
{NEW:2}` is `{NEW:2}` (existing-only key dropped). This is exactly what
`env sync --merge` vs `--reconcile-exact` does.

**`env set` then `env list` (behavior).** After `nagarectl env set notes FOO bar`,
`nagarectl env list notes` shows a row `runtime FOO bar`. With `--dry-run`, the
rendered ConfigMap's `data` is `{"FOO":"bar"}` and its `metadata.name` is
`nagare-env-notes-runtime`. (Substitute `hello` and the example config for a
runnable demo; `notes` is the canonical example name used across the env plans.)

**`env sync --reconcile-exact` drops a stale key (behavior).** Given the store
already holds `{OLD:x, FOO:bar}` and `.env` contains only `FOO=bar` and `NEW=1`:
`nagarectl env sync notes --file .env --reconcile-exact` makes the store exactly
`{FOO:bar, NEW:1}` — `OLD` is dropped. The same command with `--merge` (or no mode
flag) yields `{OLD:x, FOO:bar, NEW:1}` — `OLD` is kept. Demonstrate the rendered
ConfigMap difference with `--dry-run` (the live drop is observable via the live
check).

**`secret set` reads stdin; `secret list` hides values (behavior).**
`printf 'topsecret' | nagarectl secret set notes API_KEY` (or interactively with
a hidden prompt) sets the value without it appearing in `argv` or shell history.
`nagarectl secret list notes` afterwards prints `API_KEY` and never the value.
With `--dry-run`, `secret set` prints a `Secret` manifest whose `data.API_KEY` is
the base64 of the stdin value (`dG9wc2VjcmV0` for `topsecret`), proving the value
flowed from stdin.

**`--dry-run` touches no cluster.** Every `set`/`delete`/`sync` and `secret
set`/`delete` under `--dry-run` prints the manifest and applies nothing; the demos
in Concrete Steps run with no kube context. (The dry-run still *reads* the current
store to compute the reconciled result; with no cluster that read is the
empty-store case, so the render still succeeds.)

**Test commands.** `cd cli/nagarectl && cabal test` runs the `Nagare.Env.Dotenv`
and reconcile-mode groups (M1, M2). `cd cli/nagarectl && cabal build` compiles the
new `env`/`secret` handlers (M2, M3). The `--dry-run` invocations in Concrete
Steps are the behavioral acceptance for the CLI surface without a cluster; the
optional live check (Step 6) is the end-to-end proof against `tan-nb-exp`.


## Idempotence and Recovery

Every step is safe to repeat. Creating the module, editing the cabal file, and
editing `Main.hs` are idempotent (re-running `cabal build`/`cabal test` just
rebuilds).

The CLI mutations are idempotent at the cluster level because EP-24's
`writeEnvStore`/`writeSecretStore` are `kubectl apply` (declarative: applying the
same desired map twice converges to the same resource). Therefore:

- `env set APP KEY VALUE` run twice with the same value is a no-op net change: the
  first write sets `KEY=VALUE`; the second reconciles the same key to the same
  value and re-applies an identical manifest.
- `env delete APP KEY` run twice is safe: the first removes the key; the second
  reads a store without the key, deletes nothing, and re-applies the same map.
- `env sync APP --file F` is safe to re-run: with `--merge` it converges to the
  union; with `--reconcile-exact` it converges to exactly the file. Re-running
  either against the same file is a no-op net change.

The one data-safety rule, inherited from EP-24: a read that returns `Left` (a
present-but-malformed ConfigMap/Secret) must **not** be followed by a write. The
handlers above use `orDie =<< readEnvStore ...`, so a malformed existing store
aborts the command with a one-line error before any write — never silently
overwriting real values. To recover from a bad store write, re-run the command
with the correct values (apply is convergent), or `kubectl delete` the resource
to return the app to the "never configured" state (the Service's `envFrom` uses
`optional: true`, so the app still deploys with an absent store).

A `--dry-run` is always safe and side-effect-free; use it to preview any mutation
before applying it.


## Interfaces and Dependencies

**New module (this plan).** `cli/nagarectl/src/Nagare/Env/Dotenv.hs`, registered
in `cli/nagarectl/nagarectl.cabal` (`exposed-modules` of the `library` stanza).
Its full public contract:

```haskell
module Nagare.Env.Dotenv (parseDotenv) where

-- | Parse a dotenv file's text into a key/value map. KEY=VALUE per line;
-- blanks and #-comments ignored; optional leading "export "; single/double
-- quotes stripped (inner # literal); quoted values may span lines; a non-blank
-- line with no '=' or an empty key is Left. No shell interpolation.
parseDotenv :: Text -> Either Text (Map Text Text)
```

**New CLI surface (this plan, in `cli/nagarectl/app/Main.hs`).** New `Command`
constructors `Env EnvCommand` and `Secret SecretCommand`; the `EnvCommand` sum
(`EnvList`, `EnvSet`, `EnvDelete`, `EnvSync`) and `SecretCommand` sum
(`SecretSet`, `SecretList`, `SecretDelete`); the option records `StoreCommonOpts`
and `ScopeSelection`; the parsers `appArg`, `storeCommonOptsParser`,
`configFileOpt`, `scopeSelectionParser`, `reconcileModeParser`, `envCmd`/
`envSubparser`, `secretCmd`/`secretSubparser`; the pure helpers `selectedScopes ::
ScopeSelection -> [EnvScope]` and `reconcileModeFrom :: Bool -> ReconcileMode`;
the identity helper `appIdentityOrDie :: FilePath -> IO (Text, Text)` and
`resolveAppOrDie :: StoreCommonOpts -> IO (Text, Text)`; the handlers `runEnv ::
EnvCommand -> IO ()` and `runSecret :: SecretCommand -> IO ()`; and the dry-run
printers `applyOrDryRunEnv`/`applyOrDryRunSecret`, the table formatter
`formatEnvRows`, and `readSecretValue :: IO Text` (stdin/TTY value reader).

**The command grammar this plan commits to:**

```text
nagarectl env list   APP [-f|--config CONFIG] [--all]
nagarectl env set    APP KEY VALUE [-f|--config CONFIG] [--runtime] [--build] [--preview] [--dry-run]
nagarectl env delete APP KEY       [-f|--config CONFIG] [--runtime] [--build] [--preview] [--dry-run]
nagarectl env sync   APP --file FILE [-f|--config CONFIG]
                         [--runtime] [--build] [--preview] [--merge | --reconcile-exact] [--dry-run]
nagarectl secret set    APP KEY    [-f|--config CONFIG] [--runtime] [--build] [--preview] [--dry-run]   # value from stdin
nagarectl secret list   APP        [-f|--config CONFIG] [--all]
nagarectl secret delete APP KEY    [-f|--config CONFIG] [--runtime] [--build] [--preview] [--dry-run]
```

Defaults: scope defaults to `--runtime`; `env sync` mode defaults to `--merge`
(Merge); the config file defaults to `nagare/Config.hs`. `--merge` and
`--reconcile-exact` are mutually exclusive. The positional `APP` must match the
app name in the loaded config (a mismatch is a hard error). The config file uses
`-f/--config` here (not `--file`) so `env sync`'s dotenv argument can use `--file`
exactly as the roadmap spells it.

**Hard dependency — EP-24, `Nagare.Env.Store`** (in
`cli/nagarectl/src/Nagare/Env/Store.hs`, delivered by
`docs/plans/24-per-app-secret-and-configmap-store-with-reconcile-modes.md`). This
plan imports and consumes, unchanged:

```haskell
data ReconcileMode = Merge | ReconcileExact
reconcile        :: ReconcileMode -> Map Text Text -> Map Text Text -> Map Text Text
renderEnvConfigMap :: Text -> Text -> EnvScope -> Map Text Text -> ByteString
renderEnvSecret    :: Text -> Text -> EnvScope -> Map Text Text -> ByteString
readEnvStore     :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))
readSecretStore  :: Text -> Text -> EnvScope -> IO (Either Text (Map Text Text))
writeEnvStore    :: Text -> Text -> EnvScope -> Map Text Text -> IO ()
writeSecretStore :: Text -> Text -> EnvScope -> Map Text Text -> IO ()
```

If EP-24 is not merged, this plan cannot compile (the import fails). Stop and
coordinate; do not stub the store (it is a hard dependency by design).

**Soft dependency — EP-23, `nagare-dsl`** (from
`docs/plans/23-scoped-env-model-and-scoped-knative-renderer.md`). This plan
imports, from the `nagare-dsl` library:

```haskell
data EnvScope = Runtime | Build | Preview     -- Nagare.Dsl.Types
scopeToken           :: EnvScope -> Text       -- Nagare.Dsl.Render (or Types per IP2)
-- (managedConfigMapName / managedSecretName are used transitively via EP-24's render fns)
```

`EnvScope` is required for the `--runtime/--build/--preview` flags and is
available transitively through EP-24 (which imports it), so the hard dependency on
EP-24 already covers it. `scopeToken` is used for the dry-run section headers and
the `env list` SCOPE column; if it is not yet exported, fall back to a local
`show`-based token (`Runtime->"runtime"` etc.) and replace it with the import when
EP-23 lands — record the choice in the Decision Log.

**Existing helpers reused (already in `cli/nagarectl/app/Main.hs`).**
`fileOpt`/`dryRunOpt`/`ghcEnvOpt` (option fragments), `provisionGhcEnv` (GHC
environment), `dieT`/`orDie` (error exits), `siteIdentityOrDie` and
`siteConfigIdentity` (site identity), and `defaultConfigFile`. From
`cli/nagare-dsl/src/Nagare/Dsl/Load.hs`: `loadDeployment`, `loadSite`,
`renderLoadError`, and the `LoadError (UnexpectedKind)` constructor. From
`Nagare.Dsl.Types`/`Nagare.Dsl.Static.Types`: `serviceNameText`, `namespaceText`,
`siteNameText`.

**Libraries.** `optparse-applicative` (already a dependency of the `nagarectl`
executable), `containers` (`Data.Map`), `text`, `bytestring` — all already
present or added in Step 1. The new module needs no new package. The stdin/TTY
secret reader uses `System.IO` (`hSetEcho`, `hIsTerminalDevice`) and
`Control.Exception (bracket_)` from `base` — no new dependency.

**Consumers (downstream).** EP-28
(`docs/plans/28-env-and-secret-management-docs-and-end-to-end-example.md`)
documents this command surface and exercises it end to end. Keep the command
grammar above stable so that documentation stays accurate.
