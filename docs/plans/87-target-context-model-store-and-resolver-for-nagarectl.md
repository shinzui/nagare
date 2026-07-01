---
id: 87
slug: target-context-model-store-and-resolver-for-nagarectl
title: "Target context model store and resolver for nagarectl"
kind: exec-plan
created_at: 2026-06-30T23:48:03Z
intention: "intention_01kwdepj5gey18qqy0pjjx3mep"
master_plan: "docs/masterplans/17-first-class-target-contexts-for-nagare.md"
---

# Target context model store and resolver for nagarectl

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today the nagare command-line tool (`nagarectl`) figures out **which GCP project,
region, registry, buckets, apps domain, VM, build architecture, and cloud-vs-local
mode it is acting on** by reading process environment variables. Those variables are
populated, per working directory, from one git-ignored file: `nagare.target.env` for a
cloud target, or `nagare.local.env` together with `NAGARE_MODE=local` for local mode.
Because that file and the in-repo Pulumi state are keyed to the current directory, the
unit of "a nagare instance" is a *checkout*: to act on a second project you make a
second clone, or you edit the file and re-run `direnv allow`. There is no notion of a
*named, selectable target*.

This ExecPlan builds the foundation for **first-class, named target contexts** — the
same idea `kubectl` uses with `--context` and `kubectl config use-context`. A
**context** is a complete, named target bundle stored in a user-level directory; an
operator can keep many (for example a `tan-nb-exp` cloud context, a `labs` context on a
different project, and a `local` laptop context), mark one as the default, and later
select any of them per command. This plan is the **keystone** of MasterPlan
`docs/masterplans/17-first-class-target-contexts-for-nagare.md`: it defines the context
*contract* — the data model, the on-disk store layout, and the resolution precedence —
that every sibling plan consumes. It does **not** add the `nagarectl context` commands
or the `--context` flag (that is `docs/plans/88-nagarectl-context-command-group-and-context-selection.md`),
the shell/`direnv` reader (`docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md`),
the per-context Pulumi state (`docs/plans/90-per-context-pulumi-state-and-config-projection.md`),
or the manifest de-hardcoding (`docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md`).
It builds only the Haskell model, the store path helpers, the context file reader, and
the **context-aware resolver** inside `cli/nagarectl/src/Nagare/Target.hs`.

What someone gains after this change: the single Haskell resolution point,
`Nagare.Target.resolveTargetProfile`, becomes context-aware. A new function
`resolveActiveContext :: Maybe Text -> IO TargetProfile` resolves the *active context*
following a precise precedence — an explicit context name (later fed by the `--context`
flag) or the `NAGARE_CONTEXT` environment variable, then the `current-context` pointer
file, then an in-repo `nagare.target.env`/`nagare.local.env` (back-compat with the
older single-profile model), then the built-in `tan-nb-exp` defaults — while keeping the
existing rule that **per-field environment variables still win** over the chosen
context. How to see it working: a new unit-test group exercises every precedence tier
(a stored context resolves; `NAGARE_CONTEXT` selects it; a per-field env var overrides
one of its values; with nothing configured the historic `tan-nb-exp` defaults still
appear; a `mode=local` context resolves to `Local`). The pre-existing back-compat tests
that assert "defaults reproduce the tan-nb-exp worked example" continue to pass
unchanged, proving the generalization did not regress the single-profile behavior.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [ ] M1: Context model + store layout. Add `ContextName` (newtype + smart constructor
  `mkContextName`/accessor `contextNameText`) and the XDG-aware store-path helpers
  (`nagareConfigDir`, `contextsDir`, `contextFilePath`, `currentContextPath`) to
  `cli/nagarectl/src/Nagare/Target.hs`. Document the `.env` schema (one `export VAR=value`
  line per field, matching `nagare.target.env.example`). Reserve the Pulumi-state
  location as a `ContextName`-derived helper (`contextStateDirName`), deferring its path
  scheme to `docs/plans/90-per-context-pulumi-state-and-config-projection.md`.
- [ ] M2: Context-aware resolver. Add the context file reader (`parseContextEnv`,
  `readContextMap`, `readCurrentContext`), the selection logic (`selectContextName`,
  `loadActiveContextMap`), the field resolver over a context map (`resolveProfileFrom`),
  and the public `resolveActiveContext :: Maybe Text -> IO TargetProfile`. Rework
  `resolveTargetProfile` to delegate (`resolveActiveContext Nothing`), preserving the
  env-override-then-default semantics and the registry/bucket derivations.
- [ ] M3: Unit tests in `cli/nagarectl/test/Spec.hs` — precedence ordering, env overrides
  context, in-repo-profile back-compat, defaults-reproduce-tan-nb-exp (extend the
  existing assertions with store isolation), mode folding (a `mode=local` context resolves
  to `Local`), and `parseContextEnv` parsing.
- [ ] `cd cli/nagarectl && cabal build -v0 exe:nagarectl` succeeds and `cabal test`
  passes with the extended and new groups green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The `TargetProfile` record in `cli/nagarectl/src/Nagare/Target.hs` (lines ~53–88)
  **already carries every context field** the MasterPlan enumerates — `tpProject`,
  `tpRegion`, `tpZone`, `tpRegistryHost`, `tpArtifactRegistryId`, `tpImageBucket`,
  `tpBackupBucket`, `tpBaseDomain`, `tpInstanceName`, `tpTargetPlatform`, `tpMode`,
  `tpLocalObjectStore` — because MasterPlan 16 already added `tpMode`/`tpLocalObjectStore`.
  So "extend the `TargetProfile` record" is effectively a no-op here: EP-87 does **not**
  add a context field to the record. The only genuinely new surface is the *store*, the
  *reader*, and the *selection precedence* layered into resolution. This is recorded so a
  future contributor does not waste effort re-deriving fields that already exist.

(Otherwise none yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: a context's on-disk form is the **same flat `export VAR=value` file** the
  existing profiles already use (`nagare.target.env`/`nagare.local.env`), one file per
  context, **not** a YAML/kubeconfig document.
  Rationale: the contract has two consumers — Haskell (`Nagare.Target`) and bash
  (`.envrc`, `scripts/lib/target.sh`, consumed by sibling
  `docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md`).
  A flat `export` file is sourced directly by bash with **no YAML parser**, and the
  schema is identical to today's `nagare.target.env.example`, so an in-repo profile is
  still honored and nothing in MasterPlan 12/16 has to change. A YAML kubeconfig would
  force a parser into the dependency-free bash layer for no functional gain in v1.
  Date: 2026-06-30

- Decision: the store lives under **`${XDG_CONFIG_HOME:-$HOME/.config}/nagare`** — context
  files at `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env` and a
  `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/current-context` text file naming the default.
  Rationale: a *user-level* store (not per-checkout) is the whole point — one operator,
  many named targets, one checkout. XDG is the cross-tool convention and is trivially
  overridable in tests (set `XDG_CONFIG_HOME` to a temp dir for a hermetic store).
  Date: 2026-06-30

- Decision: the **selection precedence** (which bundle becomes the active context) is,
  highest first: an explicit context name argument (later the `--context` flag from
  sibling `docs/plans/88-nagarectl-context-command-group-and-context-selection.md`) **or**
  the `NAGARE_CONTEXT` environment variable > the `current-context` pointer > an in-repo
  `./nagare.target.env` (overlaid by `./nagare.local.env` when local) > the built-in
  `tan-nb-exp` default. **Separately**, per-field environment variables
  (`CLOUDSDK_*`, `NAGARE_*`) override the chosen context's fields (`env > context >
  default`). The two are orthogonal: the first picks the *bundle*, the second lets a
  single variable win over that bundle, preserving today's "environment wins" rule.
  Rationale: this mirrors `kubectl` (`--context`/`KUBECONFIG`-style selection) while
  retaining the exact env-override semantics MasterPlan 12 shipped, so existing operators
  and `.envrc` exports keep behaving identically.
  Date: 2026-06-30

- Decision: a context name that is *explicitly* requested (argument, `NAGARE_CONTEXT`, or
  the `current-context` pointer) but whose file is **missing** is a hard error, not a
  silent fall-through to defaults.
  Rationale: silently targeting the `tan-nb-exp` default when the operator asked for
  `labs` could push changes at the wrong project. Failing loudly is the fail-closed
  direction the isolation policy (CLAUDE.md) demands. The fall-through tiers (in-repo
  profile, defaults) apply only when **no** context was selected at all.
  Date: 2026-06-30

- Decision: `mode` is **folded into the context** — a context whose `.env` contains
  `export NAGARE_MODE=local` (plus the local registry host, base domain, and object
  store) *is* MasterPlan 16's local profile. There is no separate "local context"
  type; `tpMode` is just another resolved field.
  Rationale: MasterPlan 17 explicitly subsumes the `NAGARE_MODE` + `nagare.local.env`
  pair into "a context with `mode=local`". Keeping `tpMode` a plain field means
  `storeBackendFor` and the existing local-mode machinery work unchanged.
  Date: 2026-06-30

- Decision: the per-context **Pulumi-state location** is *reserved here but not designed
  here*. EP-87 exposes only a name-deriving helper (`contextStateDirName :: ContextName ->
  Text`) and does **not** add a state field to `TargetProfile`. The actual backend path
  scheme, the `Pulumi.dev.yaml` projection, and the relocation are owned by sibling
  `docs/plans/90-per-context-pulumi-state-and-config-projection.md`.
  Rationale: the state location is derived from the *context name*, which is not a
  resolved env field, so it does not belong on the field-bundle record; and its concrete
  layout is EP-90's Integration Point 5, not EP-87's. Reserving the name now lets EP-90
  build on a stable hook without EP-87 over-reaching.
  Date: 2026-06-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this repository. Read it fully before editing.

nagare is an opinionated deployment system. Its command-line tool, `nagarectl`, is a
Haskell program built with `cabal`. The package lives at `cli/nagarectl/`; its build
description is `cli/nagarectl/nagarectl.cabal`, its library modules under
`cli/nagarectl/src/Nagare/`, its entry point `cli/nagarectl/app/Main.hs`, and its test
suite `cli/nagarectl/test/Spec.hs` (a single `tasty` test tree). The library already
depends on the `directory`, `filepath`, `containers`, `text`, and `temporary` packages
(see the `build-depends` stanza in `cli/nagarectl/nagarectl.cabal`), so no new dependency
is required by this plan.

**The single resolution point.** Everything nagare needs to know about *where* it is
deploying is computed in one module: `cli/nagarectl/src/Nagare/Target.hs`. The function
`resolveTargetProfile :: IO TargetProfile` (around lines 101–131) reads a fixed set of
environment variables and returns a fully-resolved `TargetProfile` record (defined around
lines 53–88). Every field is final — downstream code never does another environment
lookup or applies another literal fallback. The fields are:

- `tpProject` — the GCP project id, from `CLOUDSDK_CORE_PROJECT`, default `tan-nb-exp`.
- `tpRegion` — from `CLOUDSDK_COMPUTE_REGION`, default `us-west1`.
- `tpZone` — from `CLOUDSDK_COMPUTE_ZONE`, default `us-west1-a`.
- `tpRegistryHost` — from `NAGARE_REGISTRY_HOST`, **derived** default `<region>-docker.pkg.dev`.
- `tpArtifactRegistryId` — from `NAGARE_ARTIFACT_REGISTRY_ID`, default `nagare`.
- `tpImageBucket` — from `NAGARE_IMAGE_BUCKET`, **derived** default `<project>-nagare-images`.
- `tpBackupBucket` — from `NAGARE_BACKUP_BUCKET`, **derived** default `<project>-nagare-backups`.
- `tpBaseDomain` — from `NAGARE_BASE_DOMAIN`, default `apps.example.com`.
- `tpInstanceName` — from `NAGARE_INSTANCE_NAME`, default `nagare-01`.
- `tpTargetPlatform` — from `NAGARE_TARGET_PLATFORM`, default `linux/amd64`.
- `tpMode` — from `NAGARE_MODE`, a `Mode` (`Cloud | Local`); default `Cloud`.
- `tpLocalObjectStore` — from `NAGARE_LOCAL_OBJECT_STORE`, default `""` (empty).

Resolution today uses a helper `envOr :: String -> Text -> IO Text` (around lines
161–168): it calls `System.Environment.lookupEnv`, and if the variable is unset **or set
to the empty string** it returns the supplied default; otherwise it returns the value.
This "empty is unset" rule matches shell `${VAR:-default}` and must be preserved. `tpMode`
is special: it is computed by `parseMode :: Maybe String -> Mode` (around lines 46–49)
applied to the raw `lookupEnv "NAGARE_MODE"`, where `"local"` (case-insensitive) is
`Local` and everything else — including unset, `"cloud"`, or a typo — is `Cloud`.

Two derived helpers also live in this module and must keep working: `registryPrefix ::
TargetProfile -> Text` (lines ~93–95), which builds `<host>/<project>/<repo-id>`; and
`storeBackendFor :: TargetProfile -> Text -> Either Text StoreBackend` (lines ~147–159),
the one place the cloud-vs-local object-store backend is chosen from `tpMode`.

**How the resolved value is used.** `cli/nagarectl/app/Main.hs` calls
`resolveTargetProfile` in many commands; for example `runInit` (around line 1892) uses it
to seed prompt defaults before writing a profile. `cli/nagarectl/src/Nagare/Init.hs`
exposes `renderTargetEnv :: TargetProfile -> Text` (around lines 112–126), which emits the
flat `export VAR=value` lines of `nagare.target.env` — the exact same schema a context
file will use. **Outside Haskell**, the same variable contract is read by `.envrc`
(direnv) and `scripts/lib/target.sh`; those are bash and are out of scope for this plan
(sibling `docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md`
makes them context-aware), but the contract this plan defines must remain bash-sourceable
(flat `export` lines), which is why the store format is not YAML.

**The worked example and the tracked schema files.** `nagare.target.env.example` (tracked
in git) documents the cloud schema and ships the `tan-nb-exp`/`us-west1`/`us-west1-a`
values; `nagare.local.env.example` documents the local schema (`NAGARE_MODE=local`, the
k3d registry host, the `sslip.io` loopback domain, the in-cluster MinIO object store). An
operator copies the example to the git-ignored real file. A **context `.env` uses the same
line format**: comment lines beginning with `#`, blank lines, and `export NAME=value`
lines. There is no new syntax.

**Existing tests you must not break.** `cli/nagarectl/test/Spec.hs` contains the group
`Nagare.Target (EP-62)` → `targetProfileTests` (around lines 414–479). It mutates the
process environment, asserts that with everything unset the defaults reproduce the
`tan-nb-exp` worked example, that project/region overrides re-derive the host and buckets,
that explicit derived vars win, that `NAGARE_TARGET_PLATFORM` overrides and empty falls
back, and that `NAGARE_LOCAL_OBJECT_STORE` resolves verbatim. The `modeResolutionTests`
group (around lines 486–508) asserts `parseMode`'s table and that `resolveTargetProfile`
reads `NAGARE_MODE`. There are also fixed `TargetProfile` literals (`initProfile`,
`tnbProfile`) used across the file; if you add a field to `TargetProfile` (this plan does
**not**) you would have to update every literal. These tests are the back-compat
guarantee and must stay green; the new tests extend them.

**Term definitions used in this plan.**

- *Context* — a named, fully-resolved target bundle: exactly the `TargetProfile` fields
  above, plus the context's Pulumi-state location (reserved here, designed in EP-90). On
  disk it is one flat `export VAR=value` file named `<name>.env`.
- *Store* — the user-level directory holding context files and the `current-context`
  pointer, rooted at `${XDG_CONFIG_HOME:-$HOME/.config}/nagare`.
- *current-context pointer* — a one-line text file `current-context` naming the default
  context (the analogue of `kubectl`'s `current-context`).
- *Active context* — the context selected for a given command after applying the
  selection precedence.
- *XDG* — the XDG Base Directory convention: user config lives under `$XDG_CONFIG_HOME`,
  falling back to `$HOME/.config` when that variable is unset.


## Plan of Work

The work is three milestones inside `cli/nagarectl/src/Nagare/Target.hs` and
`cli/nagarectl/test/Spec.hs`. Each is independently verifiable by `cabal build` and
`cabal test`. All additions are purely additive — no existing function signature changes
except that `resolveTargetProfile` is rewritten to *delegate*, keeping its type
(`IO TargetProfile`) and observable behavior identical when nothing context-related is set.

### Milestone M1 — Context model + store layout

Scope: introduce the *names and paths* a context lives under, with no behavior change to
resolution yet. At the end of M1, `Nagare.Target` exports a `ContextName` type and the
store-path helpers, the module compiles, and the existing test suite is untouched and
still green.

Edits, all in `cli/nagarectl/src/Nagare/Target.hs`:

1. Add imports: `import System.Directory (doesFileExist)`,
   `import System.FilePath ((</>), (<.>))`, `import qualified Data.Map.Strict as Map`,
   `import Data.Map.Strict (Map)`, and `import System.Environment (lookupEnv, getEnvironment)`
   (extend the existing `lookupEnv` import). Keep `OverloadedStrings`.

2. Add a `ContextName` newtype with a smart constructor. A context name becomes a
   *filename* (`<name>.env`), so it must be a safe, single path segment:

   ```haskell
   -- | The name of a stored context. It is used verbatim as a filename
   -- (@<name>.env@) and as the value of the @current-context@ pointer, so it is
   -- restricted to a single safe path segment: non-empty, and composed only of
   -- ASCII letters, digits, '-', '_', and '.', with no '/', no leading '.', and
   -- not "." or "..". 'mkContextName' is the only way to build one.
   newtype ContextName = ContextName Text
     deriving stock (Eq, Ord, Show)

   contextNameText :: ContextName -> Text
   contextNameText (ContextName t) = t

   mkContextName :: Text -> Either Text ContextName
   mkContextName raw
     | T.null raw                 = Left "context name must not be empty"
     | T.any (== '/') raw         = Left "context name must not contain '/'"
     | raw == "." || raw == ".."  = Left "context name must not be '.' or '..'"
     | T.isPrefixOf "." raw       = Left "context name must not start with '.'"
     | T.all isSafe raw           = Right (ContextName raw)
     | otherwise                  = Left "context name may use only letters, digits, '-', '_', '.'"
     where
       isSafe c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ['-','_','.']
   ```

   This needs `import Data.Char (isAsciiLower, isAsciiUpper, isDigit)` added to the
   existing `Data.Char (toLower)` import.

3. Add the XDG-aware store-path helpers. The config root honors `XDG_CONFIG_HOME`,
   falling back to `$HOME/.config`:

   ```haskell
   -- | The nagare user-level config root: @${XDG_CONFIG_HOME:-$HOME/.config}/nagare@.
   -- An unset OR empty XDG_CONFIG_HOME falls back to @$HOME/.config@ (the "empty is
   -- unset" rule, matching shell @${VAR:-default}@). With HOME also unset, the root
   -- is a relative @.config/nagare@ — acceptable because every caller that touches
   -- the store sets HOME or XDG_CONFIG_HOME (tests set XDG_CONFIG_HOME to a temp dir).
   nagareConfigDir :: IO FilePath
   nagareConfigDir = do
     xdg  <- lookupEnv "XDG_CONFIG_HOME"
     home <- lookupEnv "HOME"
     let base = case xdg of
           Just p | not (null p) -> p
           _ -> maybe ".config" (</> ".config") home
     pure (base </> "nagare")

   contextsDir :: IO FilePath
   contextsDir = (</> "contexts") <$> nagareConfigDir

   contextFilePath :: ContextName -> IO FilePath
   contextFilePath name = do
     dir <- contextsDir
     pure (dir </> T.unpack (contextNameText name) <.> "env")

   currentContextPath :: IO FilePath
   currentContextPath = (</> "current-context") <$> nagareConfigDir
   ```

4. Reserve the Pulumi-state location as a name derivation only (EP-90 owns the rest):

   ```haskell
   -- | The per-context Pulumi-state directory *name* (a single path segment derived
   -- from the context name). RESERVED by EP-87; the absolute backend path, the stack,
   -- and the Pulumi.dev.yaml projection are owned by
   -- docs/plans/90-per-context-pulumi-state-and-config-projection.md. Kept here so the
   -- context contract names the slot, not its layout.
   contextStateDirName :: ContextName -> Text
   contextStateDirName = contextNameText
   ```

5. Extend the module export list to include `ContextName (..)` (or `ContextName`,
   `mkContextName`, `contextNameText`), `nagareConfigDir`, `contextsDir`,
   `contextFilePath`, `currentContextPath`, and `contextStateDirName`. Leave the existing
   exports (`TargetProfile (..)`, `Mode (..)`, `parseMode`, `resolveTargetProfile`,
   `registryPrefix`, `minioCredentialsSecret`, `storeBackendFor`) in place.

Acceptance for M1: `cd cli/nagarectl && cabal build -v0 exe:nagarectl` succeeds; the full
existing `cabal test` still passes (no test changed yet). The `.env` schema is documented
in this plan (see *Concrete Steps*) and matches `nagare.target.env.example`.

### Milestone M2 — Context-aware resolver

Scope: layer the store into resolution. At the end of M2, `Nagare.Target` exposes
`resolveActiveContext :: Maybe Text -> IO TargetProfile`, and `resolveTargetProfile`
delegates to it. With no store and no env, behavior is byte-for-byte identical to today.

Edits, all in `cli/nagarectl/src/Nagare/Target.hs`:

1. **Context file parser.** Parse a context `.env`'s text into a `Map String Text` of
   variable → value. Skip blank and comment lines; on a `NAME=VALUE` line strip an
   optional leading `export ` and optional surrounding single/double quotes:

   ```haskell
   -- | Parse a flat @export VAR=value@ context file into a variable map. Blank lines
   -- and lines whose first non-space character is '#' are ignored. A leading
   -- @export @ is stripped; the key is everything before the first '=', the value is
   -- everything after (with one layer of surrounding single or double quotes removed).
   -- An empty value is kept as "" and treated as "unset" later by 'ctxOr'. This is a
   -- pragmatic reader, not a full shell parser: the files are machine-generated by
   -- 'Nagare.Init.renderTargetEnv' or copied from the tracked *.example schema.
   parseContextEnv :: Text -> Map String Text
   parseContextEnv = Map.fromList . concatMap lineKV . T.lines
     where
       lineKV raw =
         let s = T.stripStart raw
          in if T.null s || "#" `T.isPrefixOf` s
               then []
               else
                 let s' = maybe s id (T.stripPrefix "export " s)
                  in case T.breakOn "=" s' of
                       (k, v)
                         | T.null v  -> []
                         | otherwise -> [(T.unpack (T.strip k), unquote (T.drop 1 v))]
       unquote v =
         let t = T.strip v
          in if T.length t >= 2 && (T.head t == '"' || T.head t == '\'') && T.last t == T.head t
               then T.drop 1 (T.dropEnd 1 t)
               else t
   ```

2. **Store readers.**

   ```haskell
   -- | Read a context file into a variable map, or 'Nothing' if the path is absent.
   readContextMap :: FilePath -> IO (Maybe (Map String Text))
   readContextMap path = do
     exists <- doesFileExist path
     if exists then Just . parseContextEnv <$> TIO.readFile path else pure Nothing

   -- | Read the current-context pointer, validated through 'mkContextName'. A missing
   -- file, an empty file, or an invalid name yields 'Nothing' (no default context).
   readCurrentContext :: IO (Maybe ContextName)
   readCurrentContext = do
     path <- currentContextPath
     exists <- doesFileExist path
     if not exists
       then pure Nothing
       else do
         t <- T.strip <$> TIO.readFile path
         pure (either (const Nothing) Just (mkContextName t))
   ```

   This needs `import qualified Data.Text.IO as TIO`.

3. **Selection.** Compute the active context map following the precedence. An explicit
   name (argument or `NAGARE_CONTEXT`) and the pointer are *named* selections whose file
   must exist; absence of any named selection falls through to the in-repo profile, then
   to an empty map (defaults):

   ```haskell
   -- | The explicitly-selected context name, if any: the caller's argument (later the
   -- --context flag, docs/plans/88) wins over NAGARE_CONTEXT. Both are validated.
   selectContextName :: Maybe Text -> IO (Either Text (Maybe ContextName))
   selectContextName arg = do
     envName <- lookupEnv "NAGARE_CONTEXT"
     let raw = case arg of
           Just a | not (T.null a) -> Just a
           _ -> case envName of
             Just e | not (null e) -> Just (T.pack e)
             _ -> Nothing
     pure $ case raw of
       Nothing -> Right Nothing
       Just r  -> Right . Just <$> mkContextName r  -- Left propagates an invalid name

   -- | The active context's variable map. Precedence (highest first): an explicit /
   -- NAGARE_CONTEXT-named context > the current-context pointer > an in-repo
   -- ./nagare.target.env (overlaid by ./nagare.local.env when local) > empty (defaults).
   -- A *named* context (explicit, env, or pointer) whose file is missing is an error.
   loadActiveContextMap :: Maybe Text -> IO (Either Text (Map String Text))
   loadActiveContextMap arg = do
     sel <- selectContextName arg
     case sel of
       Left err -> pure (Left ("invalid context name: " <> err))
       Right (Just name) -> requireNamed name
       Right Nothing -> do
         ptr <- readCurrentContext
         case ptr of
           Just name -> requireNamed name
           Nothing   -> Right <$> inRepoMap
     where
       requireNamed name = do
         path <- contextFilePath name
         m <- readContextMap path
         pure $ case m of
           Just kv -> Right kv
           Nothing ->
             Left ("context \"" <> contextNameText name <> "\" not found (expected " <> T.pack path <> ")")
   ```

   The in-repo back-compat map reproduces what `.envrc` does today — source
   `./nagare.target.env`, and overlay `./nagare.local.env` when local mode is in effect
   (either `NAGARE_MODE=local` is already in the environment, or the local file itself
   sets it):

   ```haskell
   -- | The in-repo profile as a context map (MasterPlan 12/16 back-compat). Reads
   -- ./nagare.target.env, then overlays ./nagare.local.env iff local mode applies.
   -- Returns an empty map when neither file exists (so the built-in defaults reproduce
   -- tan-nb-exp). Mirrors the precedence in .envrc.
   inRepoMap :: IO (Map String Text)
   inRepoMap = do
     base  <- maybe Map.empty id <$> readContextMap "nagare.target.env"
     local <- readContextMap "nagare.local.env"
     envMode <- lookupEnv "NAGARE_MODE"
     let localIsActive = case local of
           Nothing -> False
           Just kv ->
             (fmap (map toLower) envMode == Just "local")
               || (fmap (T.toLower) (Map.lookup "NAGARE_MODE" kv) == Just "local")
     pure $ case (localIsActive, local) of
       (True, Just kv) -> Map.union kv base  -- local overlays base (left-biased union)
       _ -> base
   ```

4. **Field resolver over a context map.** Generalize `envOr` so the fallback layer is the
   context map, not just the default. Keep "empty is unset" at both the env and context
   layers:

   ```haskell
   -- | Resolve one field with precedence: process env > context map > default. An env
   -- var or a context value that is set-but-empty is treated as unset, matching shell
   -- ${VAR:-default} and the original 'envOr'.
   ctxOr :: Map String Text -> String -> Text -> IO Text
   ctxOr ctx name def = do
     m <- lookupEnv name
     pure $ case m of
       Just v | not (null v) -> T.pack v
       _ -> case Map.lookup name ctx of
              Just v | not (T.null v) -> v
              _ -> def

   -- | The raw 'Maybe String' for a field with the same env > context precedence, for
   -- 'parseMode' (which must distinguish unset from "cloud"). Empty is unset.
   ctxRaw :: Map String Text -> String -> IO (Maybe String)
   ctxRaw ctx name = do
     m <- lookupEnv name
     pure $ case m of
       Just v | not (null v) -> Just v
       _ -> case Map.lookup name ctx of
              Just v | not (T.null v) -> Just (T.unpack v)
              _ -> Nothing
   ```

5. **`resolveProfileFrom`.** This is the body of the old `resolveTargetProfile`, with
   every `envOr` replaced by `ctxOr ctx` and the `parseMode` source replaced by
   `ctxRaw ctx "NAGARE_MODE"`. The derived defaults still use the *resolved* region/project,
   so derivation is unchanged:

   ```haskell
   resolveProfileFrom :: Map String Text -> IO TargetProfile
   resolveProfileFrom ctx = do
     project <- ctxOr ctx "CLOUDSDK_CORE_PROJECT" "tan-nb-exp"
     region  <- ctxOr ctx "CLOUDSDK_COMPUTE_REGION" "us-west1"
     zone    <- ctxOr ctx "CLOUDSDK_COMPUTE_ZONE" "us-west1-a"
     registryHost <- ctxOr ctx "NAGARE_REGISTRY_HOST" (region <> "-docker.pkg.dev")
     registryId   <- ctxOr ctx "NAGARE_ARTIFACT_REGISTRY_ID" "nagare"
     imageBucket  <- ctxOr ctx "NAGARE_IMAGE_BUCKET" (project <> "-nagare-images")
     backupBucket <- ctxOr ctx "NAGARE_BACKUP_BUCKET" (project <> "-nagare-backups")
     baseDomain   <- ctxOr ctx "NAGARE_BASE_DOMAIN" "apps.example.com"
     instanceName <- ctxOr ctx "NAGARE_INSTANCE_NAME" "nagare-01"
     targetPlatform <- ctxOr ctx "NAGARE_TARGET_PLATFORM" "linux/amd64"
     mode <- parseMode <$> ctxRaw ctx "NAGARE_MODE"
     localObjectStore <- ctxOr ctx "NAGARE_LOCAL_OBJECT_STORE" ""
     pure TargetProfile { tpProject = project, tpRegion = region, tpZone = zone
                        , tpRegistryHost = registryHost, tpArtifactRegistryId = registryId
                        , tpImageBucket = imageBucket, tpBackupBucket = backupBucket
                        , tpBaseDomain = baseDomain, tpInstanceName = instanceName
                        , tpTargetPlatform = targetPlatform, tpMode = mode
                        , tpLocalObjectStore = localObjectStore }
   ```

6. **Public resolver + delegation.**

   ```haskell
   -- | Resolve the active context into a fully-derived 'TargetProfile'. The argument is
   -- an explicit context name (later fed by the --context flag, docs/plans/88); 'Nothing'
   -- means "no explicit selection", so resolution falls to NAGARE_CONTEXT, then the
   -- current-context pointer, then the in-repo profile, then the built-in defaults. A
   -- named-but-missing context throws (fail-closed). Per-field env vars override the
   -- chosen context (env > context > default).
   resolveActiveContext :: Maybe Text -> IO TargetProfile
   resolveActiveContext arg = do
     e <- loadActiveContextMap arg
     case e of
       Left err  -> ioError (userError (T.unpack err))
       Right ctx -> resolveProfileFrom ctx

   -- | Back-compat entry point: resolve with no explicit context selection.
   resolveTargetProfile :: IO TargetProfile
   resolveTargetProfile = resolveActiveContext Nothing
   ```

7. Export `resolveActiveContext`, `parseContextEnv`, `readContextMap`, `readCurrentContext`
   (the readers are useful to EP-88's command group). Keep `resolveTargetProfile` exported.

Acceptance for M2: the module compiles; `resolveTargetProfile` with an empty environment
and no store still yields the `tan-nb-exp` profile; a context map containing
`CLOUDSDK_CORE_PROJECT=labs-proj` (and nothing else) resolves `tpProject = "labs-proj"`
with derived buckets `labs-proj-nagare-*`; a process env `CLOUDSDK_CORE_PROJECT` overrides
that context value. These are proven by M3's tests.

### Milestone M3 — Unit tests

Scope: add a `Nagare.Target contexts (EP-87)` test group to `cli/nagarectl/test/Spec.hs`
and harden the existing target tests for store isolation. At the end, `cabal test` passes
with new precedence coverage and the historic assertions intact.

The new tests must run hermetically: they set `XDG_CONFIG_HOME` to a fresh temporary
directory (so a developer's real `~/.config/nagare` cannot leak in), build a tiny store by
writing `<tmp>/nagare/contexts/<name>.env` and optionally `<tmp>/nagare/current-context`,
and run from a working directory with no in-repo `nagare.target.env` (the test suite's CWD
is `cli/nagarectl/`, which has none). Use `System.IO.Temp.withSystemTempDirectory` (the
`temporary` package, already a dependency and already imported in `Spec.hs`) and
`System.Directory.createDirectoryIfMissing`.

Because both the existing `targetProfileTests` and the new tests mutate global process
state (the environment and, indirectly, the store via `XDG_CONFIG_HOME`/`NAGARE_CONTEXT`),
they must remain a single sequential `testCase` each (tasty runs cases in parallel) and
restore the environment with `finally`. Extend the existing `targetProfileTests`
`allTargetVars` save/restore list with `NAGARE_CONTEXT` and `XDG_CONFIG_HOME`, and at the
top of that test set `XDG_CONFIG_HOME` to an empty temp dir and `unsetEnv "NAGARE_CONTEXT"`
so the historic "defaults reproduce tan-nb-exp" assertion cannot be perturbed by a real
store on the machine running the tests. (This is the only change to the existing test, and
it strengthens, not weakens, the back-compat guarantee.)

New cases to add (each phrased as an observable behavior):

- *Stored context resolves via NAGARE_CONTEXT.* Write `contexts/labs.env` containing
  `export CLOUDSDK_CORE_PROJECT=labs-proj` and `export CLOUDSDK_COMPUTE_REGION=europe-west1`;
  set `NAGARE_CONTEXT=labs`; assert `tpProject == "labs-proj"`, `tpRegistryHost ==
  "europe-west1-docker.pkg.dev"`, `tpImageBucket == "labs-proj-nagare-images"`.
- *Explicit argument beats NAGARE_CONTEXT.* With `NAGARE_CONTEXT=labs` set and a second
  `contexts/prod.env` (`CLOUDSDK_CORE_PROJECT=prod-proj`), assert
  `resolveActiveContext (Just "prod")` yields `tpProject == "prod-proj"`.
- *current-context pointer selects when nothing explicit.* Write `current-context`
  containing `labs`, unset `NAGARE_CONTEXT`; assert `resolveActiveContext Nothing` yields
  `tpProject == "labs-proj"`.
- *Per-field env overrides the chosen context.* With `NAGARE_CONTEXT=labs`, additionally
  `setEnv "CLOUDSDK_CORE_PROJECT" "override-proj"`; assert `tpProject == "override-proj"`
  but `tpRegion == "europe-west1"` (still from the context). This is the `env > context >
  default` rule.
- *Defaults reproduce tan-nb-exp with an empty store.* With `XDG_CONFIG_HOME` pointing at a
  store that has no `current-context` and no contexts, and `NAGARE_CONTEXT` unset, assert
  `resolveActiveContext Nothing` yields `tpProject == "tan-nb-exp"`, `tpRegistryHost ==
  "us-west1-docker.pkg.dev"`. (This is the same guarantee as the historic test, now also
  asserted through the context path.)
- *Mode folding.* Write `contexts/local.env` with `export NAGARE_MODE=local` plus
  `export NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000`,
  `export NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io`, and
  `export NAGARE_LOCAL_OBJECT_STORE=http://minio:9000/nagare-backups`; set
  `NAGARE_CONTEXT=local`; assert `tpMode == Local`, `tpRegistryHost` and `tpBaseDomain`
  follow the file, and `storeBackendFor tp (tpBackupBucket tp)` is a `Right` `MinioBackend`.
- *Named-but-missing context fails.* Set `NAGARE_CONTEXT=ghost` with no `contexts/ghost.env`;
  assert `resolveActiveContext Nothing` throws (use `Control.Exception.try` and
  `assertBool` on a `Left`).
- *`parseContextEnv` parsing (pure).* Assert that a sample with a comment line, a blank
  line, an `export A=1` line, a bare `B=two` line, a quoted `C="three"` line, and an empty
  `D=` line parses to `fromList [("A","1"),("B","two"),("C","three"),("D","")]`, and that
  `Map.lookup "D"` resolves through `ctxOr` to the *default* (empty is unset). (If `ctxOr`
  is not exported, assert the empty-is-unset behavior end-to-end via a context file whose
  `CLOUDSDK_CORE_PROJECT=` is empty resolving to `tan-nb-exp`.)

Acceptance for M3: `cd cli/nagarectl && cabal test` passes; the new group reports its cases
green and the pre-existing `Nagare.Target (EP-62)` and `Nagare.Target mode (EP-83)` groups
still pass.


## Concrete Steps

All commands run from the repository root unless a `cd` is shown. The Haskell toolchain
(`cabal`, `ghc`) comes from the project flake dev-shell; if commands are not found, run
them inside `nix develop` / `direnv` as the repo normally does.

**The context `.env` schema** (identical to `nagare.target.env.example`; one
`export VAR=value` line per `TargetProfile` field). A cloud context file looks like:

```bash
# context: labs (generated by nagarectl, docs/plans/88) — schema == nagare.target.env.example
export CLOUDSDK_CORE_PROJECT=labs-proj
export CLOUDSDK_COMPUTE_REGION=europe-west1
export CLOUDSDK_COMPUTE_ZONE=europe-west1-b
export NAGARE_REGISTRY_HOST=europe-west1-docker.pkg.dev
export NAGARE_ARTIFACT_REGISTRY_ID=nagare
export NAGARE_IMAGE_BUCKET=labs-proj-nagare-images
export NAGARE_BACKUP_BUCKET=labs-proj-nagare-backups
export NAGARE_BASE_DOMAIN=labs.topagentnetwork.net
export NAGARE_INSTANCE_NAME=nagare-01
export NAGARE_TARGET_PLATFORM=linux/amd64
```

A local-mode context additionally carries `export NAGARE_MODE=local` and the loopback
values (registry host, base domain, object store), exactly as `nagare.local.env.example`
shows. There is no new key beyond the documented schema.

**M1/M2 — build the library and the executable.**

```bash
cd cli/nagarectl && cabal build -v0 exe:nagarectl
```

Expected: the build completes with no output (or only download/compile progress) and exit
status 0. A type error here means an import or signature was missed — re-check the M1/M2
edits against the snippets above.

**M3 — run the test suite.**

```bash
cd cli/nagarectl && cabal test
```

Expected transcript (abbreviated; case counts will differ as suites grow):

```text
nagarectl
  ...
  Nagare.Target (EP-62)
    resolveTargetProfile honors env vars and falls back to defaults: OK
  Nagare.Target mode (EP-83)
    parseMode: local (any case) is Local, else Cloud: OK
    resolveTargetProfile reads NAGARE_MODE: OK
  Nagare.Target contexts (EP-87)
    stored context resolves via NAGARE_CONTEXT: OK
    explicit argument beats NAGARE_CONTEXT: OK
    current-context pointer selects when nothing explicit: OK
    per-field env overrides the chosen context: OK
    empty store reproduces tan-nb-exp: OK
    mode=local context resolves Local with MinIO backend: OK
    named-but-missing context fails loudly: OK
    parseContextEnv parses export/bare/quoted/empty lines: OK
  ...
All N tests passed
```

A focused run while iterating (tasty's `--pattern`):

```bash
cd cli/nagarectl && cabal test --test-options='--pattern "EP-87"'
```

This runs only the new group. Expected: every case reports `OK` and the suite exits 0.


## Validation and Acceptance

Acceptance is behavioral and proven by the test suite, because the resolver is internal
(its effect surfaces through every command that reads a `TargetProfile`). The following
input→output pairs define correctness; each maps to a test in M3.

1. **Empty store, empty env → tan-nb-exp.** With `XDG_CONFIG_HOME` pointing at a directory
   that has no `nagare/current-context` and no `nagare/contexts/*.env`, no `NAGARE_*`/
   `CLOUDSDK_*` set, and no in-repo profile in the CWD, `resolveActiveContext Nothing`
   returns `tpProject = "tan-nb-exp"`, `tpRegion = "us-west1"`, `tpRegistryHost =
   "us-west1-docker.pkg.dev"`, `tpImageBucket = "tan-nb-exp-nagare-images"`,
   `tpMode = Cloud`. (Identical to today; the historic `targetProfileTests` also still
   passes.)

2. **`NAGARE_CONTEXT` selects a stored context.** With `contexts/labs.env` setting project
   `labs-proj` and region `europe-west1`, and `NAGARE_CONTEXT=labs`,
   `resolveActiveContext Nothing` returns `tpProject = "labs-proj"`, `tpRegistryHost =
   "europe-west1-docker.pkg.dev"`, `tpBackupBucket = "labs-proj-nagare-backups"`.

3. **Explicit argument beats `NAGARE_CONTEXT`.** With `NAGARE_CONTEXT=labs` and a stored
   `prod` context, `resolveActiveContext (Just "prod")` returns `tpProject = "prod-proj"`.

4. **`current-context` pointer.** With `current-context` containing `labs` and
   `NAGARE_CONTEXT` unset, `resolveActiveContext Nothing` returns the `labs` bundle.

5. **Per-field env beats the context (env > context > default).** With `NAGARE_CONTEXT=labs`
   and the process env `CLOUDSDK_CORE_PROJECT=override-proj`, the result has
   `tpProject = "override-proj"` while `tpRegion` is still `europe-west1` from the context.

6. **Mode folding.** A `local` context with `NAGARE_MODE=local` resolves `tpMode = Local`,
   and `storeBackendFor tp (tpBackupBucket tp)` returns `Right (MinioBackend …)` (proving
   the local object store is honored through the context — no separate `NAGARE_MODE`
   plumbing).

7. **Named-but-missing context fails closed.** `NAGARE_CONTEXT=ghost` with no
   `contexts/ghost.env` makes `resolveActiveContext Nothing` raise an `IOError` mentioning
   the missing path, rather than silently returning the `tan-nb-exp` default.

8. **In-repo back-compat.** With no store but an in-repo `./nagare.target.env` in the CWD
   setting `CLOUDSDK_CORE_PROJECT=repo-proj`, `resolveActiveContext Nothing` returns
   `tpProject = "repo-proj"` (MasterPlan 12 behavior preserved). (This case is best
   exercised with `withSystemTempDirectory` as the CWD; it is optional but recommended.)

The whole acceptance is: `cd cli/nagarectl && cabal test` is green, including both the
new `Nagare.Target contexts (EP-87)` group and the unchanged `EP-62`/`EP-83` groups.


## Idempotence and Recovery

Every step here is additive and repeatable. `cabal build` and `cabal test` are
idempotent; re-running them after a partial edit simply recompiles. The code changes
touch only `cli/nagarectl/src/Nagare/Target.hs` (additions plus the delegation rewrite of
`resolveTargetProfile`) and `cli/nagarectl/test/Spec.hs` (a new group plus the
store-isolation hardening of one existing test); if a build fails midway, fix the named
function and rebuild — nothing is left in a broken external state because no files outside
the repo are written by this plan.

The resolver itself is *read-only* with respect to the store: it never creates or mutates
`~/.config/nagare` (writing contexts is EP-88's job). The tests create their store under a
`withSystemTempDirectory` temp dir that is removed automatically, and they save/restore
every environment variable they touch with `finally`, so re-running the suite leaves the
environment and the developer's real `~/.config/nagare` untouched. If a test ever leaks an
env var (e.g. an aborted run), the values are the standard `CLOUDSDK_*`/`NAGARE_*` plus
`NAGARE_CONTEXT`/`XDG_CONFIG_HOME`; unset them in your shell and re-run.

Recovery from a regression: because `resolveTargetProfile`'s type and default behavior are
unchanged, reverting this plan is a clean `git revert` of the two files; the rest of the
CLI compiles against the same signature either way.


## Interfaces and Dependencies

Libraries (all already in `cli/nagarectl/nagarectl.cabal` `build-depends`; no new
dependency): `directory` (`System.Directory.doesFileExist`, `createDirectoryIfMissing`),
`filepath` (`System.FilePath.(</>)`, `(<.>)`), `containers` (`Data.Map.Strict`), `text`
(`Data.Text`, `Data.Text.IO`), `base` (`System.Environment.lookupEnv`, `Data.Char`),
and `temporary` (`System.IO.Temp.withSystemTempDirectory`, test-only).

The following types and signatures must exist in `cli/nagarectl/src/Nagare/Target.hs` at
the end of this plan (module path `Nagare.Target`):

```haskell
-- Context naming (M1)
newtype ContextName = ContextName Text
contextNameText  :: ContextName -> Text
mkContextName    :: Text -> Either Text ContextName

-- Store layout (M1) — XDG-aware paths
nagareConfigDir    :: IO FilePath          -- ${XDG_CONFIG_HOME:-$HOME/.config}/nagare
contextsDir        :: IO FilePath          -- <config>/contexts
contextFilePath    :: ContextName -> IO FilePath   -- <config>/contexts/<name>.env
currentContextPath :: IO FilePath          -- <config>/current-context

-- Pulumi-state location: RESERVED here, designed in docs/plans/90-…
contextStateDirName :: ContextName -> Text

-- Context reading (M2)
parseContextEnv    :: Text -> Map String Text
readContextMap     :: FilePath -> IO (Maybe (Map String Text))
readCurrentContext :: IO (Maybe ContextName)

-- Resolution (M2) — the context-aware single resolution point
resolveActiveContext :: Maybe Text -> IO TargetProfile
resolveTargetProfile :: IO TargetProfile   -- = resolveActiveContext Nothing

-- Unchanged, still exported
data TargetProfile = TargetProfile { tpProject, tpRegion, tpZone, tpRegistryHost
                                   , tpArtifactRegistryId, tpImageBucket, tpBackupBucket
                                   , tpBaseDomain, tpInstanceName, tpTargetPlatform
                                   , tpLocalObjectStore :: !Text
                                   , tpMode :: !Mode }
data Mode = Cloud | Local
parseMode       :: Maybe String -> Mode
registryPrefix  :: TargetProfile -> Text
storeBackendFor :: TargetProfile -> Text -> Either Text StoreBackend
```

Internal helpers (not necessarily exported, but named for the implementer):
`selectContextName`, `loadActiveContextMap`, `inRepoMap`, `ctxOr`, `ctxRaw`,
`resolveProfileFrom`.

**Dependents (defined elsewhere, named for orientation, not built here):**

- `docs/plans/88-nagarectl-context-command-group-and-context-selection.md` — adds the
  `nagarectl context list|current|use|show|create|delete` commands and the global
  `--context` flag, calling `resolveActiveContext (Just name)` and reading/writing the
  store via `contextFilePath`/`currentContextPath`/`contextsDir`/`mkContextName`. It also
  makes `nagarectl init` write a context file (reusing the `renderTargetEnv` schema).
- `docs/plans/89-shell-and-direnv-context-resolution-and-the-context-aware-guardrail.md` —
  re-implements the *same* selection precedence in bash (`.envrc`, `scripts/lib/target.sh`),
  sourcing the identical flat `<name>.env` files (the reason the store format is not YAML),
  and reworks the fail-closed guardrail against the active context's project.
- `docs/plans/90-per-context-pulumi-state-and-config-projection.md` — owns the concrete
  Pulumi-state path scheme and the `Pulumi.dev.yaml` projection; it builds on the reserved
  `contextStateDirName`.
- `docs/plans/91-de-hardcode-cluster-manifests-and-nixos-registry-from-the-active-context.md` —
  templates applied manifests/Nix from the resolved context's fields.

**Commit trailers.** Commits for this plan carry:

```text
MasterPlan: docs/masterplans/17-first-class-target-contexts-for-nagare.md
ExecPlan: docs/plans/87-target-context-model-store-and-resolver-for-nagarectl.md
Intention: intention_01kwdepj5gey18qqy0pjjx3mep
```
