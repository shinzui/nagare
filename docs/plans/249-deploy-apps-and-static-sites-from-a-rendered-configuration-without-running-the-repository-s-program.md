---
id: 249
slug: deploy-apps-and-static-sites-from-a-rendered-configuration-without-running-the-repository-s-program
title: "Deploy apps and static sites from a rendered configuration without running the repository's program"
kind: exec-plan
created_at: 2026-11-07T16:50:58Z
master_plan: "docs/masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-07T16:50:58Z
---

# Deploy apps and static sites from a rendered configuration without running the repository's program

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

A Nagare configuration is a Haskell program, `nagare/Config.hs`, that prints JSON. Every command that reads one runs it
with `runghc`, so whoever deploys a repository also runs that repository's code with their own environment and files.
For an operator deploying their own app that is fine. For a deployer holding credentials on behalf of many engineers it
is not: an engineer's config program could read the deployer's kubeconfig or store key.

After this plan the program runs once, where there is nothing to steal, and its output travels as data:

```bash
nagarectl app render -f nagare/Config.hs --out rendered.json      # in the build, no credentials
nagarectl app deploy --rendered rendered.json --tag T --image-resource R --save-plan DIR   # in the deployer
```

`site render` and `site deploy --rendered` do the same for static and server sites, and `app check --rendered`
validates a rendered document. A deployer context refuses every config program outright. The deployer also no longer
needs GHC at all, so its image and start-up shrink.

This is a child of
[MasterPlan 33](../masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md)
and delivers UC-4's `deploy-without-running-repository-code`
([UC-4](../use-cases/004-engineers-deploy-sites-by-pushing-through-a-delegated-deployer.md)) with Kotei. Kotei's
`mori://shinzui/kotei/plans/136-run-forge-builds-in-credential-free-kubernetes-jobs` produces the documents in its build
and `mori://shinzui/kotei/plans/138-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer` deploys
them. Render and `--rendered` are useful to any client and start at once; only D5 waits for
[EP-247](247-review-a-bounded-namespace-delegation-for-a-named-deployer-and-record-who-applied-each-change.md)'s actor.


## Progress

Interpreter evidence first; the local-context run only confirms
([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)).

- [ ] D1, render: `nagarectl app render -f FILE [--out PATH]` and `nagarectl site render -f FILE [--out PATH]` run the
  program once through the existing loader, decode it with the same decoder the deploy commands use, and print a
  `rendered-application` or `rendered-site` document: `contractVersion: 1`, `document`, `nagareVersion` (the rendering
  binary's version), `kind` (`Application`, `StaticSite` or `ServerSite`), `configDigest` (the SHA-256 of the program's
  exact stdout) and `config` (that stdout, as JSON). Render needs no context, store, cluster or credentials, and refuses
  a program that decodes to another kind. Evidence: unit tests over the app and site fixtures in `cli/nagarectl/test/fixtures/`, a golden sample per document under `docs/api/samples/`, and a test that render with an empty environment
  apart from `PATH` succeeds.
- [ ] D2, deploy from a rendered document: `app check`, `app deploy` (dry run, save plan and apply), `site deploy`
  (static and server, dry run and save plan) and `site preview deploy` accept `--rendered PATH` in place of `-f FILE`,
  exactly one of the two. They verify `contractVersion`, `document`, `kind` and that `configDigest` matches `config`, then
  call the existing decoders (`decodeApplication` in `cli/nagare-dsl/src/Nagare/Dsl/Load/Application.hs`, `decodeSite`
  in `cli/nagare-dsl/src/Nagare/Dsl/Load/Site.hs`) and continue on the path `-f` already takes, without
  `provisionGhcEnv`. The saved review's scope bytes are identical to the ones `-f` produces for the same program.
  Evidence: a test per command that renders a fixture and compares the compiled scope of `--rendered` with `-f`
  byte for byte, and refusal tests for a wrong kind, a digest mismatch, a newer `contractVersion` and malformed JSON.
- [ ] D3, a rendered document is untrusted input: decoding a rendered document never runs a process, never reads a path
  named inside it, and refuses unknown top-level members. Evidence: a test that a `config` naming a file path or a
  command is decoded as data or refused, never acted on, and a fuzz test over the decoders that every input either
  decodes or returns a `LoadError`.
- [ ] D4, the contract: `rendered-application` and `rendered-site` are added to `docs/api/README.md` as a new
  **input** class (documents a client hands to `nagarectl`), with their types in `cli/nagare-contract`, the regenerated
  `docs/api/openapi.json` and the samples. The `config` member is declared as the configuration JSON of the rendering
  version; its own schema is the DSL's, versioned by `nagareVersion`, and `--rendered` refuses a document rendered by a
  newer Nagare minor version than the deploying one. Evidence: `nagare-api-server-test` and the `/Contract/` goldens
  pass.
- [ ] D5, no config programs in a deployer context: when the active profile is a deployer context (EP-247's
  `NAGARE_DEPLOYER`), every path that would run a config program returns a typed `ConfigProgramRefused` error naming the
  command and `--rendered`, before starting any process. The check sits in the one place every loader passes through,
  `runConfigUntil` in `cli/nagare-dsl/src/Nagare/Dsl/Load/Process.hs` (which `runConfig` and `runConfigWith` call), so a loader added later is covered. Evidence: a
  test that calls every exported `load*` from `cli/nagare-dsl/src/Nagare/Dsl/Load/File.hs` with the deployer variable set
  and a program that would write a marker file, and proves each returns `ConfigProgramRefused` and the marker is absent.
- [ ] D6, the local confirmation: on a local context a fixture app and a fixture static site are rendered in a shell
  with no Nagare context, then deployed with `--rendered` from a deployer context; `-f` in the deployer context is
  refused. Evidence: an audit file under `docs/audits/`.
- [ ] D7, docs: `docs/user/deploying-apps.md`, `docs/user/static-hosting.md` and `docs/user/reference.md` describe render
  and `--rendered`, and say a CI deployer should deploy rendered documents. ADR 32's two reviewed stages are unchanged and
  the static-hosting guide says so. Evidence: the linked pages.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The rendered document carries the program's exact stdout as `config`, wrapped in a versioned envelope,
  rather than a new typed schema of the whole application.
  Rationale: the decoders already define and validate that JSON, and the deploy paths start from the decoded value, so
  the bytes `-f` sees and the bytes `--rendered` sees are the same by construction. A second typed schema would have to
  track every DSL change. The envelope's `nagareVersion` makes the decoder's version explicit, and D4 refuses a document
  from a newer minor version.
  Date: 2026-11-07

- Decision: The refusal of config programs lives in `runConfigUntil`, keyed by the deployer variable, not in each
  nagarectl command.
  Rationale: one choke point covers today's eleven loaders and any future one; a per-command check misses the next
  command added. The library reads the variable only to refuse, never to change behavior otherwise.
  Date: 2026-11-07

- Decision: A static site's packaging stays in the build. The deployer receives the image archive from `site package`
  and the rendered document, publishes the archive with `app image-plan` and deploys with `site deploy --rendered
  --skip-build`, the two reviewed stages of ADR 32.
  Rationale: `site package` reads local files and the program; it is build work. `site publish` stays the operator's
  one-command path.
  Date: 2026-11-07


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

**Terms.** A *config program* is a repository's `nagare/Config.hs`; it calls an `emit*` function from `Nagare.Dsl.Config`
and prints JSON. *Rendering* runs it and keeps that JSON. A *rendered document* is the versioned envelope this plan adds.
A *deployer context* is a context with `NAGARE_DEPLOYER` set (EP-247).

**How config programs run today.** `cli/nagare-dsl/src/Nagare/Dsl/Load/Process.hs` defines `runConfig`,
`runConfigWith` and `runConfigUntil`, which start `runghc --ghc-arg=-XGHC2024 -i<dir> <path>` with a timeout and capture stdout. Every loader in
`cli/nagare-dsl/src/Nagare/Dsl/Load/File.hs` (`loadApplication`, `loadSite`, `loadStaticSite`, `loadServerSite`,
`loadDeployment`, `loadWorker`, `loadTask`, `loadJob`, `loadBroker`, `loadDatabase`, `loadAppDatabases`) is
`runConfig path` followed by a pure `decode*` function over the bytes. The process inherits the caller's environment.
Before loading, nagarectl calls `provisionGhcEnv` (`cli/nagarectl/app/Nagare/Cli/Runtime/Config.hs`) so `runghc` finds the
DSL packages.

**Where the deploy commands load.** `app deploy` loads with `Load.loadApplication (params ^. #configPath)` in
`cli/nagarectl/app/Nagare/Cli/Commands/Application.hs` and later uses the path only as a fallback source label when
`--source` is absent. `site deploy` calls `Load.loadSite (sopts ^. #file)` in `runSiteDeploy` in
`cli/nagarectl/app/Nagare/Cli/Commands/Site.hs` and dispatches on `SiteStatic` or `SiteServer`. Apply and resume never
reload the program; they use the accepted scope ([Deploying apps](../user/deploying-apps.md)). The `--json` and
`--contract 1` documents are listed in `docs/api/README.md`, whose rules allow new documents without a version change.

**Decisions this rests on.** [ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md) packages the config
runtime with nagarectl, which is why rendering needs only the packaged binary.
[ADR 32](../adr/0032-static-publication-is-a-local-package-then-two-reviewed-stages.md) makes static publication a local
package then two reviewed stages, which this plan keeps. MasterPlan 33's trust model (ADR 35, written by EP-247) is why
the deployer never runs repository code.


## Plan of Work

Add `cli/nagarectl/src/Nagare/Rendered.hs` (new) with the envelope types, `renderApplication` and `renderSite` (run the
existing loader's process step once, keep the stdout, decode to check the kind) and `readRenderedApplication` /
`readRenderedSite` (verify the envelope, then call the existing decoder). Export a bytes-returning variant of the
process step from `Nagare.Dsl.Load` so render keeps the exact stdout. Add the `render` subcommands to the app and site
parsers, and the `--rendered` option as an alternative to `-f` on the commands in D2; at each call site, replace the
`load*` call with a function choosing between the program and the rendered document, so everything after the decoded
value is untouched. Add the `ConfigProgramRefused` constructor to `LoadError` in
`cli/nagare-dsl/src/Nagare/Dsl/Load/Error.hs` and the environment check to `runConfigUntil`. Then the contract types,
samples, openapi regeneration, docs and the local confirmation.


## Validation

```bash
just haskell-style-check
just gate-fast
cd cli/nagare-dsl && cabal test nagare-dsl-test --test-options='-p /Load/'
cd cli/nagarectl && cabal test nagarectl-test --test-options='-p /Rendered/'
cd cli/nagarectl && cabal test nagarectl-test --test-options='-p /Contract/'
cabal run --project-dir=cli/nagarectl nagare-api-openapi && git diff --exit-code docs/api/openapi.json
```

`gate-fast` does not build the `nagarectl` executable; build `exe:nagarectl` and run D6 with it before landing, since
D2 changes the app and site command modules.


## Interfaces

```haskell
-- cli/nagarectl/src/Nagare/Rendered.hs (new)
data RenderedKind = RenderedApplicationKind | RenderedStaticSiteKind | RenderedServerSiteKind
data Rendered = Rendered
  { contractVersion :: !Int
  , document :: !Text            -- "rendered-application" | "rendered-site"
  , nagareVersion :: !Text
  , kind :: !RenderedKind
  , configDigest :: !Text        -- sha256 of the exact program stdout
  , config :: !Value
  }
renderApplication :: FilePath -> IO (Either LoadError Rendered)
renderSite :: FilePath -> IO (Either LoadError Rendered)
readRenderedApplication :: FilePath -> IO (Either LoadError Application)
readRenderedSite :: FilePath -> IO (Either LoadError SiteConfig)

-- cli/nagare-dsl/src/Nagare/Dsl/Load/Error.hs
data LoadError = ... | ConfigProgramRefused !Text
```

```bash
nagarectl app render  -f nagare/Config.hs [--out rendered.json]
nagarectl site render -f nagare/Config.hs [--out rendered.json]
nagarectl app check   --rendered rendered.json
nagarectl app deploy  --rendered rendered.json --tag T --image-resource R [--save-plan DIR | --dry-run]
nagarectl site deploy --rendered rendered.json --skip-build --tag T --image-resource R [--save-plan DIR | --dry-run]
```

Kotei's build runs the two `render` commands with the Nagare version its runner pins; the runner passes only
`--rendered`.
