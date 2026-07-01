---
id: 88
slug: nagarectl-context-command-group-and-context-selection
title: "nagarectl context command group and --context selection"
kind: exec-plan
created_at: 2026-06-30T23:48:03Z
intention: "intention_01kwdepj5gey18qqy0pjjx3mep"
master_plan: "docs/masterplans/17-first-class-target-contexts-for-nagare.md"
---

# nagarectl context command group and --context selection

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today the `nagarectl` command-line tool resolves *where* it deploys — which Google
Cloud project, region, registry, buckets, apps domain, VM name, build platform, and
whether it is in cloud or local mode — from process environment variables that are
populated, per working directory, by a single git-ignored file (`nagare.target.env`
for a cloud target, or `nagare.local.env` with `NAGARE_MODE=local` for a local one).
To run a *second* target an operator needs a second checkout, or must edit that file
and re-run `direnv allow`. There is no concept of a named, selectable target.

After this plan an operator can keep **many named targets in one place and pick one
per command**, exactly the way `kubectl` works with contexts. Concretely, the
following becomes possible without leaving the current directory and without editing
any tracked or git-ignored file:

```text
$ nagarectl context create labs --project tan-ng-labs --base-domain labs.topagentnetwork.net
Wrote context 'labs' (~/.config/nagare/contexts/labs.env)

$ nagarectl context use labs
Switched to context 'labs'

$ nagarectl context list
CURRENT  NAME     PROJECT      BASE DOMAIN
*        labs     tan-ng-labs  labs.topagentnetwork.net
         default  tan-nb-exp   apps.example.com

$ nagarectl --context default deploy --dry-run     # one-off override, ignores current-context
... renders against project tan-nb-exp ...

$ nagarectl deploy --dry-run                        # uses the current context: labs
... renders against project tan-ng-labs ...
```

The user-visible behavior this plan delivers, and that the Validation section
proves, is: (1) a `nagarectl context` command group — `list`, `current`, `use`,
`show`, `create`, `delete` — that manages a user-level store of named target
bundles; (2) a global `--context <name>` flag (and the `NAGARE_CONTEXT` environment
variable) that selects, per command, which target *every* command
(`deploy`, `db`, `storage`, `app`, …) acts on; and (3) `nagarectl init` writing a
*named context* into that store and marking it current, while still writing a plain
`./nagare.target.env` when invoked without a name, so the existing single-target
workflow is unchanged.

This plan is the Haskell command-line surface of MasterPlan 17
(`docs/masterplans/17-first-class-target-contexts-for-nagare.md`). It is one of two
parallel "consumer" plans in Wave 2; the other, `docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md`,
does the equivalent for the bash scripts and is disjoint from this one (bash vs
Haskell, different files).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [ ] M1 — `nagarectl context` command group (`list`/`current`/`use`/`show`/`create`/`delete`) implemented against EP-87's store; `context create` reuses the target-field derivations; behavioral tests for the round trip.
- [ ] M2 — global `--context <name>` flag added to the top-level parser and threaded into every command's target resolution via EP-87's `resolveActiveContext`; the build-context-dir override renamed to `--build-context`; `NAGARE_CONTEXT` honored through the resolver.
- [ ] M3 — `nagarectl init [NAME]` writes a named context into the store and marks it current when `NAME` is given; still writes `./nagare.target.env` when it is not; Pulumi seeding unchanged.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: the target-selection flag is a **global** `--context <name>` placed
  before the subcommand (kubectl-style: `nagarectl --context labs deploy`), not a
  per-subcommand flag.
  Rationale: MasterPlan 17's Vision specifies the kubectl model verbatim
  (`nagarectl --context labs deploy …`). A global flag means *every* command —
  current and future — gets selection for free, with no per-command wiring beyond
  passing one value to the resolver; a per-subcommand flag would have to be added to
  ~25 option parsers and is easy to forget on a new command. The single global flag
  also matches `NAGARE_CONTEXT` (one selection mechanism, two spellings) and matches
  EP-89's bash side, where the selection is process-wide.
  Date: 2026-06-30

- Decision: rename the existing deploy/worker/app-deploy build-context-directory
  override from `--context`/`-c` to **`--build-context`** (retaining `-c`), freeing
  the long name `--context` for target selection.
  Rationale: `deploy`, `worker deploy`, and `app deploy` already define
  `--context`/`-c` meaning "override the Docker/nixpacks *build context directory*"
  (`cli/nagarectl/app/Main.hs`, `deployOptsParser`/`appDeployOptsParser`/
  `workerDeployOptsParser`). Reusing the same long name for a global *target*
  selector would let `nagarectl deploy --context labs` silently bind `labs` to the
  build directory and deploy to the wrong place — a dangerous footgun. Renaming the
  lesser-used build override is a small, documented breaking change justified by the
  MasterPlan making `--context` the central selection verb. The short `-c` stays on
  `--build-context` to limit muscle-memory breakage; the global target selector has
  no short form.
  Date: 2026-06-30

- Decision: thread the explicit `--context` flag *value* into each command's call to
  EP-87's `resolveActiveContext`, rather than mutating the process environment
  (e.g. `setenv NAGARE_CONTEXT`) at startup.
  Rationale: explicit threading keeps the precedence honest and local — an explicit
  `--context labs` outranks an ambient `NAGARE_CONTEXT=other` because it is passed as
  the highest-precedence argument, with no global mutation that other code (or tests)
  could observe. It also makes the data flow visible and unit-testable. The
  prompt-level requirement ("each handler that calls `resolveTargetProfile` must
  instead call `resolveActiveContext` with the flag value") is satisfied directly.
  Date: 2026-06-30

- Decision: `nagarectl init [NAME]` writes a *named context* into the EP-87 store
  (and marks it current) when `NAME` is supplied, and writes the legacy
  `./nagare.target.env` when it is not. `nagarectl context create NAME` is the
  lighter-weight sibling that only writes the context file (no preflight, no API
  enable, no Pulumi seed).
  Rationale: MasterPlan 17 requires `init` to produce a context, but the existing
  single-profile workflow (write `./nagare.target.env`, then `just infra-up`) must
  keep working byte-for-byte when no name is given (back-compat is a MasterPlan
  guarantee). Splitting "full onboarding" (`init`) from "just record a target"
  (`context create`) mirrors how operators actually work: onboarding a brand-new GCP
  project is rare and side-effecting; adding another context for an existing project
  is frequent and side-effect-free.
  Date: 2026-06-30

- Decision: reuse EP-87's store (`Nagare.Target.Context`) and EP-87's
  `resolveActiveContext`/renderer rather than re-implement any store or resolution
  logic in the CLI.
  Rationale: EP-87 is the single source of truth for the context model, the store
  layout, the `current-context` pointer, and the resolution precedence (MasterPlan 17
  Integration Points 1 and 2). EP-88 is a pure consumer: it reads/writes the store
  and calls the resolver. Re-deriving any of that here would fork the contract and
  break the shared behavior EP-89 also depends on.
  Date: 2026-06-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it before editing.

**What `nagarectl` is.** `nagarectl` is a Haskell command-line program — the deploy
CLI for the "nagare" platform. Its source lives under `cli/nagarectl/`. The entry
point and the entire command tree are in `cli/nagarectl/app/Main.hs`. Library code it
calls is under `cli/nagarectl/src/Nagare/…`. Tests are in
`cli/nagarectl/test/Spec.hs`. The package is built with Cabal; the executable target
is `exe:nagarectl` and the test target is `nagarectl-test`
(see `cli/nagarectl/nagarectl.cabal`).

**How the command tree is built (optparse-applicative).** `nagarectl` uses the
`optparse-applicative` library to parse arguments. The shape, in
`cli/nagarectl/app/Main.hs`:

- A single algebraic data type `Command` (around line 366) has one constructor per
  top-level command, e.g. `Deploy DeployOpts`, `Init InitOpts`, `Db DbCommand`,
  `Storage StorageCommand`. Command *groups* (like `db`, `storage`, `app`) use a
  nested ADT (`DbCommand`, `StorageCommand`, …) with one constructor per subcommand.
- `opts :: ParserInfo Command` (around line 1253) wires the tree. Its
  `commandParser` is a `subparser` whose `command "<name>" <cmdInfo>` entries
  (lines ~1262-1281) attach each top-level command, e.g.
  `command "storage" storageCmd` (~1269) and `command "init" initCmd` (~1277). Each
  `<cmdInfo>` is built with `info (<ctor> <$> <optsParser> <**> helper) (…)`. Groups
  build a nested `subparser` (e.g. `storageSubparser`, `dbSubparser`).
- `main` (around line 1825) is `execParser opts >>= \case …`, a single `case` over
  the `Command` value that calls one handler per constructor, e.g. `Init o -> runInit o`
  (~1856), `Storage scmd -> runStorage scmd`, `Deploy dopts -> runDeploy dopts`.

**How a command learns its target today.** Every handler that needs to know the GCP
target calls `resolveTargetProfile :: IO TargetProfile` from
`cli/nagarectl/src/Nagare/Target.hs`. That function reads the process environment
(the `CLOUDSDK_*` and `NAGARE_*` variables) with built-in `tan-nb-exp`/`us-west1`
fallbacks and returns a fully-resolved `TargetProfile` record (project, region, zone,
registry host, artifact-registry id, image bucket, backup bucket, base domain,
instance name, target platform, `mode :: Mode` (`Cloud`/`Local`), and
`localObjectStore`). The direct callers of `resolveTargetProfile` in
`cli/nagarectl/app/Main.hs` are `runServerStatus` (~1868), `runDoctor` (~1880),
`runInit` (~1896, for prompt defaults), and the deploy/site handlers at
lines ~2054, ~2096, ~2235, ~2332. Three thin helpers in the same file also call it
internally and are themselves called widely: `resolveBaseDomain` (~3084, used by
deploy/site/domains), `resolveBackupBucket` (~2912, used by db/storage backup), and
`resolveStoreBackend` (~2921, used by snapshot/restore). A **`TargetProfile`** is the
"target bundle"; this plan does not change its fields.

**What `nagarectl init` does today.** `runInit` (`cli/nagarectl/app/Main.hs` ~1892)
is the guided onboarding command and the only command permitted to drive Pulumi and
`gcloud`. It resolves four fields (project/region/zone/base-domain) from flags or
interactive prompts, runs a preflight, builds a derived profile with
`profileFromOpts` (`cli/nagarectl/src/Nagare/Init.hs` ~93), writes `./nagare.target.env`
via `writeTargetEnv`/`renderTargetEnv` (`Nagare/Init.hs` ~174/~112), enables GCP APIs,
and seeds the Pulumi stack config with `seedPulumiConfig`. `InitOpts`
(`Nagare/Init.hs` ~51) holds its flags; `initOptsParser`
(`cli/nagarectl/app/Main.hs` ~656) parses them.

**The dependency this plan builds on: EP-87.** This plan **hard-depends** on
`docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md`. That plan
delivers the context store and the context-aware resolver; this plan only consumes
them. A **context** is a `TargetProfile` bundle stored as a flat file of
`export VAR=value` lines (the *same* format as `nagare.target.env`, so bash can read
it without a parser). EP-87 places these files in a user-level store at
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`, and records the
default selection in a sibling file `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/current-context`
that names one context. `mode=local` in a context subsumes MasterPlan 16's
`NAGARE_MODE=local` switch.

Concretely, this plan assumes EP-87 surfaces a module — referenced here as
**`Nagare.Target.Context`** (`cli/nagarectl/src/Nagare/Target/Context.hs`) — exposing
at least the following (EP-87 owns the exact names; if any helper below is absent when
EP-88 starts, EP-88 adds it as a thin wrapper *in that EP-87-owned module*, never by
re-implementing store paths or precedence here):

```haskell
-- Filesystem layout (EP-87 owns these paths).
contextsDir         :: IO FilePath                       -- ${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts
currentContextPath  :: IO FilePath                       -- …/nagare/current-context

-- Store queries and mutations.
listContexts        :: IO [Text]                         -- names of *.env files, sorted
contextExists       :: Text -> IO Bool
readContext         :: Text -> IO (Either Text TargetProfile)   -- parse one context file
writeContext        :: Text -> TargetProfile -> IO ()    -- render + write a context file (creates the dir)
deleteContext       :: Text -> IO ()                     -- remove the context file
readCurrentContext  :: IO (Maybe Text)                   -- the current-context pointer, if any
setCurrentContext   :: Text -> IO ()                     -- write the pointer

-- The renderer used by writeContext / context show. Unlike Nagare.Init.renderTargetEnv,
-- it MUST round-trip mode and localObjectStore (NAGARE_MODE / NAGARE_LOCAL_OBJECT_STORE).
renderContextEnv    :: TargetProfile -> Text

-- The context-aware resolver. Precedence (highest first):
--   the explicit selector (Just name) > NAGARE_CONTEXT env > current-context pointer
--   > in-repo ./nagare.target.env|./nagare.local.env > built-in tan-nb-exp default,
-- with per-field environment overrides preserved (env > context > default).
resolveActiveContext :: Maybe Text -> IO TargetProfile
```

The single most important EP-87 entry point for this plan is
`resolveActiveContext :: Maybe Text -> IO TargetProfile`. Where today's code calls
`resolveTargetProfile`, this plan calls `resolveActiveContext` with the value of the
global `--context` flag (or `Nothing` when the flag is absent, letting the lower
precedence levels decide). EP-87 is expected to keep `resolveTargetProfile` working
(very likely as `resolveActiveContext Nothing`) so untouched code paths still compile.

**A note on collision.** `deploy`, `worker deploy`, and `app deploy` already define a
`--context`/`-c` option meaning the *build context directory* (`deployOptsParser` etc.
in `cli/nagarectl/app/Main.hs`). Because this plan introduces a *global* `--context`
target selector, that build override is renamed to `--build-context` (see Decision
Log). This is the one breaking CLI change in this plan.


## Plan of Work

The work is three milestones. M1 adds the new `context` command group (self-contained;
no change to existing commands). M2 adds the global selector and threads it through
every command (the cross-cutting change). M3 changes `init` to write a context. M1 is
deliberately first because it is the most isolated and gives an immediately testable
artifact (the store round-trip) before the wider M2 surgery.

### Milestone M1 — the `nagarectl context` command group

Scope: add a `context` command group with six subcommands operating purely on EP-87's
store. At the end, `nagarectl context create/list/current/use/show/delete` all work
and a behavioral test proves a create→use→list→show→delete round trip. No existing
command changes. Commands to run: `cd cli/nagarectl && cabal build -v0 exe:nagarectl`
then the transcripts in Concrete Steps. Acceptance: the transcripts reproduce, and
`cabal test nagarectl-test` passes including the new `Nagare context (EP-88)` group.

Edits, all in `cli/nagarectl/app/Main.hs` unless noted:

1. Add the import `import Nagare.Target.Context (…)` for the EP-87 store API listed in
   Context and Orientation, and ensure `renderContextEnv` and (for M3)
   `writeContext`/`setCurrentContext` are in scope. Keep the existing
   `import Nagare.Target (…)`.

2. Define the command ADTs near the other group ADTs (e.g. just after `DbCommand`):

   ```haskell
   -- | The @context@ subcommands (EP-88). Each operates on EP-87's user-level
   -- context store. @ContextShow Nothing@ shows the active context (the same one a
   -- command would deploy to); @ContextShow (Just n)@ shows context @n@.
   data ContextCommand
     = ContextList
     | ContextCurrent
     | ContextUse String                 -- ^ name
     | ContextShow (Maybe String)        -- ^ optional name; Nothing = active
     | ContextCreate String ContextCreateOpts   -- ^ name + fields
     | ContextDelete String Bool         -- ^ name + --yes
     deriving stock (Generic, Show)

   -- | Fields for @context create@ — the full TargetProfile surface, each optional.
   -- Absent fields fall back to EP-60's derivations\/defaults via the resolver
   -- (region-derived registry host, project-derived buckets, etc.), mirroring how
   -- 'Nagare.Init.profileFromOpts' builds a profile.
   data ContextCreateOpts = ContextCreateOpts
     { ccoProject            :: !(Maybe String)
     , ccoRegion             :: !(Maybe String)
     , ccoZone               :: !(Maybe String)
     , ccoBaseDomain         :: !(Maybe String)
     , ccoRegistryHost       :: !(Maybe String)
     , ccoArtifactRegistryId :: !(Maybe String)
     , ccoImageBucket        :: !(Maybe String)
     , ccoBackupBucket       :: !(Maybe String)
     , ccoInstanceName       :: !(Maybe String)
     , ccoTargetPlatform     :: !(Maybe String)
     , ccoMode               :: !(Maybe String)   -- ^ "cloud" | "local"
     , ccoLocalObjectStore   :: !(Maybe String)
     , ccoForce              :: !Bool              -- ^ overwrite an existing context
     , ccoUse                :: !Bool              -- ^ also set as current-context
     }
     deriving stock (Generic, Show)
   ```

3. Add `Context ContextCommand` as a new constructor to the top-level `Command` ADT
   (~line 366).

4. Add the option parsers (near the other `…OptsParser` definitions):

   ```haskell
   contextCreateOptsParser :: Parser ContextCreateOpts
   contextCreateOptsParser =
     ContextCreateOpts
       <$> optional (strOption (long "project"  <> metavar "PROJECT_ID" <> help "GCP project id"))
       <*> optional (strOption (long "region"   <> metavar "REGION"     <> help "Compute region (default us-west1)"))
       <*> optional (strOption (long "zone"     <> metavar "ZONE"       <> help "Compute zone (default us-west1-a)"))
       <*> optional (strOption (long "base-domain" <> metavar "DOMAIN"  <> help "Apps base domain (default apps.example.com)"))
       <*> optional (strOption (long "registry-host" <> metavar "HOST"  <> help "Artifact Registry host (default <region>-docker.pkg.dev)"))
       <*> optional (strOption (long "artifact-registry-id" <> metavar "ID" <> help "Artifact Registry repo id (default nagare)"))
       <*> optional (strOption (long "image-bucket"  <> metavar "BUCKET" <> help "Image bucket (default <project>-nagare-images)"))
       <*> optional (strOption (long "backup-bucket" <> metavar "BUCKET" <> help "Backup bucket (default <project>-nagare-backups)"))
       <*> optional (strOption (long "instance-name" <> metavar "NAME"   <> help "VM instance name (default nagare-01)"))
       <*> optional (strOption (long "target-platform" <> metavar "PLATFORM" <> help "Docker build platform (default linux/amd64)"))
       <*> optional (strOption (long "mode" <> metavar "MODE" <> help "cloud | local (default cloud)"))
       <*> optional (strOption (long "local-object-store" <> metavar "URL" <> help "Local S3 endpoint/bucket (local mode only)"))
       <*> switch   (long "force" <> help "Overwrite an existing context of this name")
       <*> switch   (long "use"   <> help "Also set this context as the current context")

   contextNameArg :: Parser String
   contextNameArg = strArgument (metavar "NAME" <> help "Context name (a DNS-label-like identifier)")
   ```

5. Add the `command "context" contextCmd` entry to the top-level `subparser` in
   `opts` (the `commandParser` block, lines ~1262-1281), and define `contextCmd`
   alongside the other `…Cmd` `where`-bindings:

   ```haskell
   contextCmd =
     info (Context <$> contextSubparser <**> helper)
       (fullDesc <> progDesc "Manage named target contexts (list, current, use, show, create, delete)")
   contextSubparser =
     subparser
       ( command "list"    (info (pure (Context ContextList)            <**> helper) (progDesc "List all contexts; mark the current one"))
      <> command "current" (info (pure (Context ContextCurrent)         <**> helper) (progDesc "Print the current context's name"))
      <> command "use"     (info (Context . ContextUse  <$> contextNameArg <**> helper) (progDesc "Set the current context"))
      <> command "show"    (info (Context . ContextShow <$> optional contextNameArg <**> helper) (progDesc "Print a context's resolved bundle (default: the active context)"))
      <> command "create"  (info (Context <$> (ContextCreate <$> contextNameArg <*> contextCreateOptsParser) <**> helper) (progDesc "Write a new context into the store"))
      <> command "delete"  (info (Context <$> (ContextDelete <$> contextNameArg <*> switch (long "yes" <> help "Confirm deletion")) <**> helper) (progDesc "Delete a context from the store"))
       )
   ```

6. Add the dispatcher arm. In `main`'s `case`, add
   `Context ccmd -> runContext mctx ccmd` (the `mctx` argument exists after M2; for an
   M1-only intermediate build, use `runContext Nothing ccmd` and tighten in M2).

7. Add a single field-builder by **extending** `Nagare.Init.profileFromOpts` rather
   than duplicating EP-60's derivations (the MasterPlan's stated single-source-of-truth
   value). Add to `cli/nagarectl/src/Nagare/Init.hs`:

   ```haskell
   -- | Build a fully-derived TargetProfile from the optional context-create fields,
   -- REUSING 'resolveTargetProfile' so the registry host\/buckets follow EP-60's
   -- derivations exactly. Each provided field is placed into the environment; each
   -- absent field is unset so its derivation/default wins (mirrors 'profileFromOpts',
   -- extended to every field plus NAGARE_MODE / NAGARE_LOCAL_OBJECT_STORE). One-shot:
   -- the caller (context create / init) exits after writing, so transient env
   -- mutation is acceptable; tests restore the environment with 'finally'.
   profileFromContextFields
     :: [(String, Maybe String)]   -- ^ (env var name, optional value) pairs
     -> IO TargetProfile
   profileFromContextFields fields = do
     forM_ fields $ \(k, mv) -> maybe (unsetEnv k) (setEnv k) mv
     resolveTargetProfile
   ```

   and a small mapping in `Main.hs` from `ContextCreateOpts` to the env-name pairs
   (`CLOUDSDK_CORE_PROJECT`, `CLOUDSDK_COMPUTE_REGION`, `CLOUDSDK_COMPUTE_ZONE`,
   `NAGARE_BASE_DOMAIN`, `NAGARE_REGISTRY_HOST`, `NAGARE_ARTIFACT_REGISTRY_ID`,
   `NAGARE_IMAGE_BUCKET`, `NAGARE_BACKUP_BUCKET`, `NAGARE_INSTANCE_NAME`,
   `NAGARE_TARGET_PLATFORM`, `NAGARE_MODE`, `NAGARE_LOCAL_OBJECT_STORE`). This keeps
   the EP-60 derivation logic in exactly one place.

8. Add the handler:

   ```haskell
   runContext :: Maybe String -> ContextCommand -> IO ()
   runContext mctx = \case
     ContextList -> do
       names <- listContexts
       cur   <- readCurrentContext
       rows  <- forM names $ \n -> do
         e <- readContext n
         pure $ case e of
           Right tp -> (n, tpProject tp, tpBaseDomain tp)
           Left _   -> (n, "(unreadable)", "")
       TIO.putStr (formatContextList cur rows)     -- a small aligned-table helper

     ContextCurrent ->
       readCurrentContext >>= maybe (dieT "no current context set") TIO.putStrLn

     ContextUse name -> do
       ok <- contextExists (T.pack name)
       if ok
         then setCurrentContext (T.pack name) >> putStrLn ("Switched to context '" <> name <> "'")
         else dieT (T.pack ("no such context: " <> name))

     ContextShow mname -> do
       tp <- case mname of
         Just n  -> either dieT pure =<< readContext (T.pack n)
         Nothing -> resolveActiveContext (T.pack <$> mctx)
       TIO.putStr (renderContextEnv tp)

     ContextCreate name o -> do
       exists <- contextExists (T.pack name)
       when (exists && not (ccoForce o)) $
         dieT (T.pack ("context '" <> name <> "' already exists; pass --force to overwrite"))
       tp <- profileFromContextFields (contextEnvPairs o)
       writeContext (T.pack name) tp
       path <- (\d -> d <> "/" <> name <> ".env") <$> contextsDir
       putStrLn ("Wrote context '" <> name <> "' (" <> path <> ")")
       when (ccoUse o) $ setCurrentContext (T.pack name) >> putStrLn ("Set current context to '" <> name <> "'")

     ContextDelete name yes -> do
       ok <- contextExists (T.pack name)
       if not ok then dieT (T.pack ("no such context: " <> name))
       else if not yes then dieT (T.pack ("refusing to delete '" <> name <> "' without --yes"))
       else do
         deleteContext (T.pack name)
         putStrLn ("Deleted context '" <> name <> "'")
         -- If it was current, leave the pointer dangling: resolveActiveContext falls
         -- through to the in-repo profile / default, which is the safe behavior.
   ```

   `formatContextList` and `contextEnvPairs` are small local helpers (an aligned
   table and the `ContextCreateOpts`→env-pairs mapping from step 7).

### Milestone M2 — the global `--context` selector threaded into every command

Scope: add the global `--context <name>` flag and make every command's target
resolution honor it via `resolveActiveContext`. At the end,
`nagarectl --context labs deploy --dry-run` renders against the `labs` context, and
`NAGARE_CONTEXT=labs nagarectl deploy --dry-run` does the same via the environment.
Commands to run: `cd cli/nagarectl && cabal build -v0 exe:nagarectl`; then the M2
transcripts. Acceptance: a `--dry-run` deploy under two different contexts renders two
different projects/registries, proving the selector reaches the build path.

Edits, all in `cli/nagarectl/app/Main.hs`:

1. Free up the long name `--context` by renaming the build-context-dir override.
   In `deployOptsParser`, `appDeployOptsParser`, and `workerDeployOptsParser`, change
   the option `long "context" <> short 'c'` to `long "build-context" <> short 'c'`
   and update its `help` to "Override the build context directory…". The record field
   names (`contextOverride`) need not change.

2. Add the global selector parser:

   ```haskell
   globalContextParser :: Parser (Maybe String)
   globalContextParser =
     optional
       ( strOption
           ( long "context"
               <> metavar "NAME"
               <> help "Target context to use for this command (overrides NAGARE_CONTEXT and the current-context pointer)"
           )
       )
   ```

3. Change `opts` to carry the global flag alongside the command, and `main` to
   destructure it:

   ```haskell
   opts :: ParserInfo (Maybe String, Command)
   opts =
     info (((,) <$> globalContextParser <*> commandParser) <**> helper)
       (fullDesc <> progDesc "nagarectl — deploy a typed Nagare app or static site to Knative")
     where commandParser = subparser ( … <> command "context" contextCmd <> … )

   main :: IO ()
   main = execParser opts >>= \(mctx, c) -> case c of
     Deploy dopts        -> runDeploy mctx dopts
     …
     Context ccmd        -> runContext mctx ccmd
     Init o              -> runInit mctx o
     …
   ```

   Because `globalContextParser` sits in the *outer* `info`, before the `subparser`,
   the flag is accepted before the command word (`nagarectl --context labs deploy`),
   which is the kubectl convention.

4. Thread `mctx :: Maybe String` into every handler that resolves a target, replacing
   each direct `resolveTargetProfile` with `resolveActiveContext (T.pack <$> mctx)`.
   To keep the change small and uniform, add one local helper:

   ```haskell
   activeProfile :: Maybe String -> IO TargetProfile
   activeProfile = resolveActiveContext . fmap T.pack
   ```

   Then:
   - `runServerStatus`, `runDoctor`, `runDeploy`, `runSiteDeploy`, `runPreviewDeploy`,
     and the other handlers currently calling `resolveTargetProfile` gain a leading
     `Maybe String` parameter and call `activeProfile mctx` instead.
   - The three internal helpers gain a `Maybe String` parameter and pass it through:
     `resolveBaseDomain :: Maybe String -> Maybe String -> IO Text`
     (selector + the existing `--base-domain` override),
     `resolveBackupBucket :: Maybe String -> Maybe String -> IO Text`, and
     `resolveStoreBackend :: Maybe String -> Maybe String -> IO StoreBackend`. Their
     call sites in the handlers pass `mctx`.
   - Handlers that never resolve a target (pure kubectl-only commands) are unchanged
     except for the `main` dispatch passing `mctx` (which they may ignore). To avoid
     touching unrelated handler signatures, an acceptable alternative is to ignore
     `mctx` in those arms (`AppList o -> runAppList o`) — only handlers that resolve a
     target must thread it. This keeps the diff proportional to the commands that
     actually have a target.

   The threading is mechanical; the compiler enforces completeness (every changed
   signature forces its callers to pass `mctx`). The Validation section proves the
   selector actually reaches the deploy path, not merely that it compiles.

### Milestone M3 — `nagarectl init` writes a named context

Scope: give `init` an optional positional `NAME`. With a name, `init` writes the
derived profile into the EP-87 store as context `NAME`, sets it current, and skips the
legacy file; without a name, it writes `./nagare.target.env` exactly as today. Pulumi
seeding and the preflight/enable steps are unchanged. Commands to run:
`cd cli/nagarectl && cabal build -v0 exe:nagarectl`; then the M3 transcript.
Acceptance: `nagarectl init labs --project … --skip-preflight --skip-enable --skip-seed`
creates `~/.config/nagare/contexts/labs.env`, sets the current-context pointer to
`labs`, and a following `nagarectl context current` prints `labs`; `nagarectl init
--project … --skip-*` (no name) still writes `./nagare.target.env`.

Edits:

1. In `cli/nagarectl/src/Nagare/Init.hs`, add `ioContextName :: !(Maybe String)` to
   `InitOpts` (the name to create; `Nothing` = legacy file).

2. In `cli/nagarectl/app/Main.hs`, `initOptsParser`, add the optional positional as
   the relevant field:
   `<*> optional (strArgument (metavar "NAME" <> help "Context name to create and make current (omit to write ./nagare.target.env)"))`.

3. In `runInit` (now `runInit :: Maybe String -> InitOpts -> IO ()`), after building
   `tp` with `profileFromOpts`, branch on `ioContextName`:
   - `Just name`: `writeContext (T.pack name) tp` (honoring `ioForce` for overwrite
     via a `contextExists` guard mirroring `context create`), then
     `setCurrentContext (T.pack name)`, and print
     `"Wrote context '<name>' and set it current"`. Do **not** write
     `./nagare.target.env`.
   - `Nothing`: the existing `writeTargetEnv`/`renderTargetEnv` path, unchanged.
   The prompt defaults at the top of `runInit` come from `activeProfile mctx` (so a
   re-run under `--context` shows that context's values); this is a no-op for the
   common case where `mctx` is `Nothing`.

4. The Pulumi seed (`seedPulumiConfig`) is unchanged in this plan. MasterPlan 17's
   EP-90 (`docs/plans/90-per-context-pulumi-state-and-config-projection.md`) owns
   making the seed per-context; it soft-depends on this plan precisely because `init`
   is where the projection is written. Leaving the seed as-is here is correct and
   does not block EP-90.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare`
unless a `cd` is shown. Build the CLI after each milestone:

```bash
cd cli/nagarectl && cabal build -v0 exe:nagarectl
```

A convenient alias for the built binary (avoids a global install):

```bash
nctl() { cabal -v0 run exe:nagarectl -- "$@"; }   # run from cli/nagarectl
```

**M1 — the context group.** Create two contexts, switch between them, inspect, and
delete:

```text
$ nctl context create labs --project tan-ng-labs --base-domain labs.topagentnetwork.net
Wrote context 'labs' (/Users/you/.config/nagare/contexts/labs.env)

$ nctl context create default --project tan-nb-exp
Wrote context 'default' (/Users/you/.config/nagare/contexts/default.env)

$ nctl context use labs
Switched to context 'labs'

$ nctl context current
labs

$ nctl context list
CURRENT  NAME     PROJECT      BASE DOMAIN
*        labs     tan-ng-labs  labs.topagentnetwork.net
         default  tan-nb-exp   apps.example.com

$ nctl context show
export CLOUDSDK_CORE_PROJECT=tan-ng-labs
export CLOUDSDK_COMPUTE_REGION=us-west1
export CLOUDSDK_COMPUTE_ZONE=us-west1-a
export NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev
export NAGARE_ARTIFACT_REGISTRY_ID=nagare
export NAGARE_IMAGE_BUCKET=tan-ng-labs-nagare-images
export NAGARE_BACKUP_BUCKET=tan-ng-labs-nagare-backups
export NAGARE_BASE_DOMAIN=labs.topagentnetwork.net
export NAGARE_INSTANCE_NAME=nagare-01
export NAGARE_TARGET_PLATFORM=linux/amd64
export NAGARE_MODE=cloud
export NAGARE_LOCAL_OBJECT_STORE=

$ nctl context show default
export CLOUDSDK_CORE_PROJECT=tan-nb-exp
...
export NAGARE_BASE_DOMAIN=apps.example.com
...

$ nctl context delete default --yes
Deleted context 'default'
```

Note the derived fields in `context show labs`: the registry host follows the region
(`us-west1-docker.pkg.dev`) and the buckets follow the project
(`tan-ng-labs-nagare-images`/`-backups`) — produced by reusing the EP-60 derivations
through `profileFromContextFields`, not hand-written.

**M2 — global selection.** Prove a one-off override and the env spelling reach the
deploy path. Run from a directory containing a deployable config (e.g.
`cluster/examples/static-site` or any app config), using `--dry-run` so nothing is
built or applied:

```text
$ nctl --context labs deploy --dry-run        # explicit selector wins over current-context
... image ref: us-west1-docker.pkg.dev/tan-ng-labs/nagare/<app>:<tag> ...

$ NAGARE_CONTEXT=default nctl deploy --dry-run  # env selects 'default' (after re-creating it)
... image ref: us-west1-docker.pkg.dev/tan-nb-exp/nagare/<app>:<tag> ...

$ nctl deploy --dry-run                        # no flag, no env: uses current-context (labs)
... image ref: us-west1-docker.pkg.dev/tan-ng-labs/nagare/<app>:<tag> ...
```

The differing project segment in the rendered image ref is the observable proof that
the selector reached `resolveActiveContext` and flowed into the build.

**M3 — init writes a context.** Side-effecting stages skipped so it is safe to run
anywhere:

```text
$ nctl init labs2 --project tan-ng-labs --base-domain labs.topagentnetwork.net \
        --skip-preflight --skip-enable --skip-seed
Wrote context 'labs2' and set it current

$ nctl context current
labs2

$ ls ~/.config/nagare/contexts/
labs.env  labs2.env

$ nctl init --project tan-nb-exp --skip-preflight --skip-enable --skip-seed   # legacy path
Wrote nagare.target.env
...
```


## Validation and Acceptance

Build and run the unit tests:

```bash
cd cli/nagarectl && cabal build -v0 exe:nagarectl && cabal test nagarectl-test
```

Add a test group `Nagare context (EP-88)` to `cli/nagarectl/test/Spec.hs`, mirroring
the existing environment-mutating style (the `targetProfileTests`/`modeResolutionTests`
groups, which run as a single sequential `testCase` and restore the environment with
`finally`). Because the context store lives at
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare`, the test sets `XDG_CONFIG_HOME` to a fresh
temporary directory for the duration (and restores it with `finally`), so it never
touches the operator's real store:

1. **Store round trip (M1).** Set `XDG_CONFIG_HOME` to a temp dir. Run the equivalent
   of `context create alpha --project p-alpha --base-domain a.example.com`; assert the
   file `…/nagare/contexts/alpha.env` exists and that `readContext "alpha"` returns a
   `TargetProfile` with `tpProject == "p-alpha"`, `tpRegistryHost ==
   "us-west1-docker.pkg.dev"` (region-derived), and `tpImageBucket ==
   "p-alpha-nagare-images"` (project-derived). Run `context use alpha`; assert
   `readCurrentContext == Just "alpha"`. Run `context delete alpha --yes`; assert
   `contextExists "alpha" == False`.

2. **Selector precedence (M2).** With the temp store holding contexts `alpha` and
   `beta` (different projects), assert `resolveActiveContext (Just "beta")` returns
   `beta`'s project even when `NAGARE_CONTEXT=alpha` is set and the current-context
   pointer names `alpha` — proving the explicit flag outranks both. Then unset the
   flag and assert `NAGARE_CONTEXT` is honored, then unset that and assert the pointer
   is honored. (This exercises EP-87's precedence through the exact entry point M2
   calls; if EP-87 already tests precedence, this test asserts the CLI passes the flag
   through unchanged.)

3. **`init` writes a context (M3).** With a temp `XDG_CONFIG_HOME`, run `runInit` with
   `ioContextName = Just "gamma"`, `ioSkipPreflight/Enable/Seed = True`, and a project;
   assert `…/nagare/contexts/gamma.env` exists, `readCurrentContext == Just "gamma"`,
   and that no `./nagare.target.env` was written. Run again with
   `ioContextName = Nothing`; assert `./nagare.target.env` is written (clean up after).

Beyond the tests, the behavioral acceptance is the Concrete Steps transcripts: the
`context show` derivations, the differing image-ref project under `--context` vs
`NAGARE_CONTEXT` vs current-context, and `context current` reflecting `init`'s name.

The `--help` output is also acceptance: `nagarectl --help` lists `context` among the
commands and shows `--context NAME` as a global option; `nagarectl deploy --help`
shows `--build-context` (not `--context`) for the build-directory override.


## Idempotence and Recovery

`context create` refuses to overwrite an existing context unless `--force` is given,
so re-running it is safe and explicit. `context use` only rewrites the pointer (an
idempotent single-file write). `context delete` requires `--yes` and is a no-op error
if the context is absent; deleting the *current* context leaves the pointer dangling,
which `resolveActiveContext` handles by falling through to the in-repo profile or the
`tan-nb-exp` default (the safe direction — it never silently targets a stale project).
`init` with a name honors `--force` the same way `context create` does, and `init`
without a name keeps its existing `RefusedExists` behavior for `./nagare.target.env`.
All store writes go through EP-87's `writeContext`/`setCurrentContext`, which create
the store directory if missing, so a first-ever `create`/`use`/`init` on a machine
with no `~/.config/nagare` works without manual setup. Every step can be repeated
without drift: the store is a set of independent flat files plus one pointer file.

If a build half-lands during M2 (signatures changed but not all call sites threaded),
the compiler fails loudly with "not in scope"/arity errors naming the exact call
site; fix forward by passing `mctx`. No persistent state is touched by a failed build.


## Interfaces and Dependencies

**Dependency on EP-87.** This plan hard-depends on
`docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md` for the store
and the resolver. The interface consumed (module referenced as
`Nagare.Target.Context`, `cli/nagarectl/src/Nagare/Target/Context.hs`) is listed in
Context and Orientation: `contextsDir`, `currentContextPath`, `listContexts`,
`contextExists`, `readContext`, `writeContext`, `deleteContext`, `readCurrentContext`,
`setCurrentContext`, `renderContextEnv`, and the keystone
`resolveActiveContext :: Maybe Text -> IO TargetProfile`. If EP-87 names a helper
differently or omits a thin one (e.g. `deleteContext`), EP-88 adds the wrapper to that
EP-87-owned module — never by re-deriving store paths or precedence in the CLI.

**Sibling plans (referenced by path, not depended on at build time).**
`docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md`
implements the same selection precedence in bash and is disjoint from this plan.
`docs/plans/90-per-context-pulumi-state-and-config-projection.md` soft-depends on this
plan's `init` for writing the per-context Pulumi projection.

**Libraries.** `optparse-applicative` (the command tree and the new global flag);
`text` (`Data.Text` for the `Text`/`String` boundary at `resolveActiveContext`);
`directory`/`System.Environment` already used by `Nagare.Init` for the env-injection
in `profileFromContextFields`. No new package dependencies are introduced; if
`Nagare.Target.Context` is a new module, it is added to the `other-modules` of both
the `nagarectl` executable and `nagarectl-test` in `cli/nagarectl/nagarectl.cabal`
(EP-87 likely does this; verify and add if missing).

**Types and signatures that must exist at the end of each milestone.**

End of M1 (`cli/nagarectl/app/Main.hs`, plus `cli/nagarectl/src/Nagare/Init.hs`):

```haskell
data ContextCommand
  = ContextList | ContextCurrent | ContextUse String
  | ContextShow (Maybe String) | ContextCreate String ContextCreateOpts
  | ContextDelete String Bool
data ContextCreateOpts = ContextCreateOpts { … }     -- the 14 fields above
-- Command gains:  | Context ContextCommand
runContext            :: Maybe String -> ContextCommand -> IO ()
contextCreateOptsParser :: Parser ContextCreateOpts
-- Nagare.Init:
profileFromContextFields :: [(String, Maybe String)] -> IO TargetProfile
```

End of M2 (`cli/nagarectl/app/Main.hs`):

```haskell
opts                 :: ParserInfo (Maybe String, Command)
globalContextParser  :: Parser (Maybe String)
activeProfile        :: Maybe String -> IO TargetProfile
resolveBaseDomain    :: Maybe String -> Maybe String -> IO Text       -- selector + override
resolveBackupBucket  :: Maybe String -> Maybe String -> IO Text
resolveStoreBackend  :: Maybe String -> Maybe String -> IO StoreBackend
-- every target-resolving handler gains a leading `Maybe String` (the selector)
```

End of M3 (`cli/nagarectl/src/Nagare/Init.hs` and `app/Main.hs`):

```haskell
-- InitOpts gains:  ioContextName :: !(Maybe String)
runInit              :: Maybe String -> InitOpts -> IO ()
```


## Revision History

- 2026-06-30 — Initial draft authored as child EP-88 of MasterPlan 17
  (`docs/masterplans/17-first-class-target-contexts-for-nagare.md`). Scope, milestones,
  interfaces, and Decision Log entries written against the EP-87 contract
  (`docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md`) and the
  current command tree in `cli/nagarectl/app/Main.hs`. Reason: establish the
  self-contained plan for the CLI context surface before implementation begins.
