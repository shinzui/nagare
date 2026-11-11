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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T03:56:33Z
      verdict: "changes-requested"
      note: "Raw stdout digest cannot be verified from parsed JSON Value; standalone worker deploy remains blocked by config-program refusal."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T04:04:19Z
      mode: "update"
      note: "Preserve exact stdout as a UTF-8 JSON string and add rendered standalone workers with round-trip acceptance."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-11T05:47:08Z
      mode: "implement"
      note: "Implemented D1-D5 and D7; D6 local confirmation pending"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-11T14:46:00Z
      mode: "implement"
      note: "Local confirmation passed at e748a550 (audit mp33-local-confirmation-2026-11-11); plan Complete"
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

`worker render` and `worker deploy --rendered` cover standalone workers. `site render` and `site deploy --rendered` do the same for static and server sites, and `app check --rendered`
validates a rendered document. A deployer context refuses every config program outright. The deployer also no longer
needs GHC at all, so its image and start-up shrink.

This is a child of
[MasterPlan 33](../masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md)
and delivers UC-4's `deploy-without-running-repository-code`
([UC-4](../use-cases/004-engineers-deploy-sites-by-pushing-through-a-delegated-deployer.md)) with Kotei. Kotei's
`mori://shinzui/kotei/plans/136-run-forge-builds-in-credential-free-kubernetes-jobs` produces the documents in its build
and `mori://shinzui/kotei/plans/138-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer` deploys
them. Render and `--rendered` are useful to any client and start at once; D5 and D6 hard-depend on
[EP-247](247-review-a-bounded-namespace-delegation-for-a-named-deployer-and-record-who-applied-each-change.md)'s actor.


## Progress

Interpreter evidence first; the local-context run only confirms
([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)).

- [x] D1, render: `nagarectl app render -f FILE [--out PATH]`, `nagarectl worker render -f FILE [--out PATH]` and `nagarectl site render -f FILE [--out PATH]` run the
  program once through the existing loader, decode it with the same decoder the deploy commands use, and print a
  `rendered-application`, `rendered-worker` or `rendered-site` document: `contractVersion: 1`, `document`, `nagareVersion` (the rendering
  binary's version), `kind` (`Application`, `Worker`, `StaticSite` or `ServerSite`), `configDigest` (the SHA-256 of the program's
  exact stdout) and `config` (the exact stdout decoded strictly as UTF-8 and stored as a JSON string, including whitespace). Render needs no context, store, cluster or credentials, and refuses
  a program that decodes to another kind. Evidence: unit tests over the app, worker and site fixtures in `cli/nagarectl/test/fixtures/`, a golden sample per document under `docs/api/samples/`, and a test that render with an empty environment
  apart from `PATH` succeeds.
  Done 2026-11-10: `app|worker|site render` (`runRender` in `cli/nagarectl/app/Nagare/Cli/Runtime/Rendered.hs`) over `renderedDocument` in `cli/nagare-dsl/src/Nagare/Dsl/Load/Rendered.hs`; goldens `docs/api/samples/rendered-{application,worker,site}.json`. The empty-environment render check moves to D6 (Decision Log).
- [x] D2, deploy from a rendered document: `app check`, `app deploy` (dry run, save plan and apply), `site deploy`
  (static and server, dry run and save plan), `worker deploy` (dry run, save plan and apply) and `site preview deploy` accept `--rendered PATH` in place of `-f FILE`,
  exactly one of the two. They verify `contractVersion`, `document`, `kind` and that `configDigest` matches the UTF-8 encoding of the decoded `config` string, then
  call the existing decoders (`decodeApplication` in `cli/nagare-dsl/src/Nagare/Dsl/Load/Application.hs`, `decodeSite`
  in `cli/nagare-dsl/src/Nagare/Dsl/Load/Site.hs`, and `decodeWorker` used by `Load/File.hs`) and continue on the path `-f` already takes, without
  `provisionGhcEnv`. The saved review's scope bytes are identical to the ones `-f` produces for the same program.
  Evidence: a test per command that renders a fixture and compares the compiled scope of `--rendered` with `-f`
  byte for byte; round-trip tests preserve trailing newlines, reordered keys, non-ASCII text and alternate outer JSON escaping while detecting a one-byte config edit; and refusal tests for a wrong kind, a digest mismatch, a newer `contractVersion` and malformed JSON.
  Done 2026-11-10: `--rendered` on `app check|deploy`, `worker deploy`, `site deploy` and `site preview deploy`, exclusive with `-f` in the parser (`configInputOpt`), decoded by the commands' own decoders without `provisionGhcEnv`. `Rendered` tests (nagare-dsl) decode an application, a worker and both site kinds from their documents to the values `-f`'s decoder yields, and keep exact bytes across trailing newlines, key order, non-ASCII and alternate escaping, refusing a one-byte edit, a wrong kind, newer contract and Nagare versions and malformed JSON.
- [x] D3, a rendered document is untrusted input: decoding a rendered document never runs a process, never reads a path
  named inside it, and refuses unknown top-level members. Evidence: a test that a `config` naming a file path or a
  command is decoded as data or refused, never acted on, and a fuzz test over the decoders that every input either
  decodes or returns a `LoadError`.
  Done 2026-11-10: `decodeRendered` refuses unknown members and runs nothing; a config naming a path or command is decoded as data; every truncation and corruption of a valid config decodes or is a `LoadError`.
- [x] D4, the contract: `rendered-application`, `rendered-worker` and `rendered-site` are added to `docs/api/README.md` as a new
  **input** class (documents a client hands to `nagarectl`), with their types in `cli/nagare-contract`, the regenerated
  `docs/api/openapi.json` and the samples. The `config` member is a string containing the configuration JSON of the rendering
  version; invalid UTF-8 output is refused, and its bytes are never normalized before hashing or decoding; its own schema is the DSL's, versioned by `nagareVersion`, and `--rendered` refuses a document rendered by a
  newer Nagare minor version than the deploying one. Evidence: `nagare-api-server-test` and the `/Contract/` goldens
  pass.
  Done 2026-11-10: `RenderedConfiguration` in `cli/nagare-contract/src/Nagare/Contract/Rendered.hs`, the input class in `docs/api/README.md`, regenerated `docs/api/openapi.json`; `/Contract/` goldens pass.
- [x] D5, no config programs in a deployer context: when the active profile is a deployer context (EP-247's
  `NAGARE_DEPLOYER`), every path that would run a config program returns a typed `ConfigProgramRefused` error naming the
  command and `--rendered`, before starting any process. The check sits in the one place every loader passes through,
  `runConfigUntil` in `cli/nagare-dsl/src/Nagare/Dsl/Load/Process.hs` (which `runConfig` and `runConfigWith` call), so a loader added later is covered. Evidence: a
  test that calls every exported `load*` from `cli/nagare-dsl/src/Nagare/Dsl/Load/File.hs` with the deployer variable set
  and a program that would write a marker file, and proves each returns `ConfigProgramRefused` and the marker is absent.
  Done 2026-11-10: `runConfigUntil` returns `ConfigProgramRefused` when `NAGARE_DEPLOYER` is set, before any process; the deployer guard exports it for a deployer context. The test calls every exported loader and `runConfigWith` with a program that writes a marker; each is refused and the marker is absent.
- [x] D6, the local confirmation: on a local context a fixture app, a fixture standalone worker and a fixture static site are rendered in a shell
  with no Nagare context, then deployed with `--rendered` from a deployer context; `-f` in the deployer context is
  refused. Evidence: an audit file under `docs/audits/`.
  Done 2026-11-11 at `e748a550` ([audit](../audits/mp33-local-confirmation-2026-11-11.md), P0, P4–P6): the four fixtures rendered under `env -i PATH=/usr/bin:/bin`; the deployer deployed the app and the static site from the workstation and the worker from a Pod with `--rendered`; `app check -f` and `app deploy -f` were refused before any process ran.
- [x] D7, docs: `docs/user/deploying-apps.md`, `docs/user/static-hosting.md` and `docs/user/reference.md` describe render
  and `--rendered`, and say a CI deployer should deploy rendered documents. ADR 32's two reviewed stages are unchanged and
  the static-hosting guide says so. Evidence: the linked pages.
  Done 2026-11-10: `docs/user/deploying-apps.md` (Deploying from a rendered configuration), `docs/user/static-hosting.md` (Deploying a rendered site; ADR 32's stages unchanged) and `docs/user/reference.md`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: D2's equality is proved on the decoded configuration value rather than on compiled scope bytes, and the
  empty-environment render check runs in D6's local run.
  Rationale: every deploy compiles its scope from the decoded value, so equal values give equal scopes; comparing
  scopes would need each command's full inventory fixture. Rendering needs a GHC environment exposing nagare-dsl,
  which only the local run has.
  Date: 2026-11-10

- Decision: The deployer guard exports `NAGARE_DEPLOYER` into the process environment for a deployer context.
  Rationale: the deployer's name lives in its context file, while the library choke point reads only the
  environment; exporting it once keeps the refusal in `runConfigUntil` for every loader.
  Date: 2026-11-10

- Decision: Preserve stdout as a JSON string instead of parsing it into an envelope Value; extend the same contract to standalone workers.
  Rationale: exact bytes remain available for digest verification, and every allowed config-based deploy command has a credential-free input path. Task run/delete consume accepted task state, so they need no new config loader.
  Date: 2026-11-08


- Decision: The rendered document carries the program's exact UTF-8 stdout as a JSON string in `config`, wrapped in a versioned envelope,
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

Apps, standalone workers and static sites can now be rendered once in a credential-free shell into versioned documents that carry the program's exact output, and deployed with `--rendered` by a client that never runs repository code; a deployer context refuses config programs at the one loader choke point. The local run [confirmed it](../audits/mp33-local-confirmation-2026-11-11.md) with no defect in this plan's paths. Nothing remains here; Kotei's build Jobs (EP-136) produce these documents. ADR 32's two reviewed stages are unchanged, and ADR 35 records why the deployer never runs the program.


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

**Where the standalone worker loads.** `cli/nagarectl/app/Nagare/Cli/Commands/Worker.hs` calls
`Load.loadWorker`; add its rendered alternative at that boundary and retain the same decoded Worker compiler path.
`task run` and `task delete` in `Commands/Task.hs` operate on accepted inventory state and do not load a program.

**Where the deploy commands load.** `app deploy` loads with `Load.loadApplication (params ^. #configPath)` in
`cli/nagarectl/app/Nagare/Cli/Commands/Application.hs` and later uses the path only as a fallback source label when
`--source` is absent. `site deploy` calls `Load.loadSite (sopts ^. #file)` in `runSiteDeploy` in
`cli/nagarectl/app/Nagare/Cli/Commands/Site.hs` and dispatches on `SiteStatic` or `SiteServer`. Apply and resume never
reload the program; they use the accepted scope ([Deploying apps](../user/deploying-apps.md)). The `--json` and
`--contract 1` documents are listed in `docs/api/README.md`, whose rules allow new documents without a version change.

**Decisions this rests on.** [ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md) packages the config
runtime with nagarectl, which is why rendering needs only the packaged binary.
[ADR 32](../adr/0032-static-publication-is-a-local-package-then-two-reviewed-stages.md) makes static publication a local
package then two reviewed stages, which this plan keeps. MasterPlan 33's accepted [trust model](../adr/0035-a-delegated-deployer-is-trusted-and-repository-content-is-not.md) is why
the deployer never runs repository code.


## Plan of Work

Add `cli/nagarectl/src/Nagare/Rendered.hs` (new) with the envelope types, `renderApplication`, `renderWorker` and `renderSite` (run the
existing loader's process step once, keep the stdout, decode to check the kind) and `readRenderedApplication` /
`readRenderedWorker` / `readRenderedSite` (verify the envelope, then call the existing decoder). Export a bytes-returning variant of the
process step from `Nagare.Dsl.Load` so render keeps the exact stdout. Add the `render` subcommands to the app, worker and site
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
D2 changes the app, worker and site command modules.


## Interfaces

```haskell
-- cli/nagarectl/src/Nagare/Rendered.hs (new)
data RenderedKind = RenderedApplicationKind | RenderedWorkerKind | RenderedStaticSiteKind | RenderedServerSiteKind
data Rendered = Rendered
  { contractVersion :: !Int
  , document :: !Text            -- "rendered-application" | "rendered-worker" | "rendered-site"
  , nagareVersion :: !Text
  , kind :: !RenderedKind
  , configDigest :: !Text        -- sha256 of the exact program stdout
  , config :: !Text         -- exact UTF-8 stdout, carried as a JSON string
  }
renderApplication :: FilePath -> IO (Either LoadError Rendered)
renderWorker :: FilePath -> IO (Either LoadError Rendered)
renderSite :: FilePath -> IO (Either LoadError Rendered)
readRenderedApplication :: FilePath -> IO (Either LoadError Application)
readRenderedWorker :: FilePath -> IO (Either LoadError Worker)
readRenderedSite :: FilePath -> IO (Either LoadError SiteConfig)

-- cli/nagare-dsl/src/Nagare/Dsl/Load/Error.hs
data LoadError = ... | ConfigProgramRefused !Text
```

```bash
nagarectl app render  -f nagare/Config.hs [--out rendered.json]
nagarectl site render -f nagare/Config.hs [--out rendered.json]
nagarectl worker render -f nagare/Worker.hs [--out rendered.json]
nagarectl worker deploy --rendered rendered.json [--save-plan DIR | --dry-run]
nagarectl app check   --rendered rendered.json
nagarectl app deploy  --rendered rendered.json --tag T --image-resource R [--save-plan DIR | --dry-run]
nagarectl site deploy --rendered rendered.json --skip-build --tag T --image-resource R [--save-plan DIR | --dry-run]
```

Kotei's build runs the applicable `render` command with the Nagare version its runner pins; the runner passes only
`--rendered`.

Revision (2026-11-08): applied the MasterPlan 33 review findings to the interfaces, acceptance and ownership described above.
