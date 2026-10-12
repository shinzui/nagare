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

Full plan before trimming: [25-nagarectl-env-and-secret-cli-commands.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/25-nagarectl-env-and-secret-cli-commands.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

