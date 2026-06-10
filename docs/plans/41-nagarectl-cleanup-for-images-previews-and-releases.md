---
id: 41
slug: nagarectl-cleanup-for-images-previews-and-releases
title: "nagarectl cleanup for images previews and releases"
kind: exec-plan
created_at: 2026-06-10T04:34:52Z
intention: "intention_01ktqwqc61e519h77zqdf3ngs3"
master_plan: "docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md"
---

# nagarectl cleanup for images previews and releases

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, when the `nagare-01` boot disk fills up, an operator has no single command to reclaim
space. They have to SSH into the VM by hand, remember that k3s uses *containerd* (not docker) so
`docker system prune` does nothing, run `sudo k3s crictl images` to eyeball what is taking room,
then separately hunt down stale static-site previews with `kubectl get ksvc` and decide which are
old enough to delete, and finally accept that per-site release-history ConfigMaps grow without
bound. Nothing ties these three space-leaks together, and every step is a manual, error-prone
judgement call performed under disk pressure.

After this plan, `nagarectl cleanup` reclaims disk and removes stale resources across three
categories in one command: (1) unused container images in the node's containerd image store, (2)
stale static-site preview deployments, and (3) old release-history entries beyond a retention
count. Crucially — because this is the **only mutating command in MasterPlan 8** — it
**defaults to a dry run**: with no flags it prints exactly what *would* be removed and how much
space would be reclaimed, and deletes nothing. Mutation requires the explicit `--confirm` flag.

The command surface:

```text
nagarectl cleanup [--images] [--previews] [--releases] [--confirm] [--preview-ttl-days N] [--keep-releases N] [-n NAMESPACE]

  (no category flags)   Act on all three categories: images, previews, releases.
  --images              Limit to the containerd image store.
  --previews            Limit to stale static-site previews.
  --releases            Limit to old release-history entries.

  --confirm             REQUIRED to delete anything. Without it, cleanup is a dry run
                        that only reports what would be removed (the default).
  --preview-ttl-days N  Previews older than N days are stale (default: 7).
  --keep-releases N     Keep the most recent N releases per log (default: 10);
                        the `current` release is always kept.
  -n, --namespace NS    Namespace to scan for previews/releases (default: from config / "default").
```

You can see it working end-to-end. With your `kubectl` context pointing at the k3s cluster and
`scripts/iap-ssh.sh` able to reach `nagare-01`, run the dry run first:

```bash
nagarectl cleanup
```

It prints a per-category report — the count and reclaimable bytes of prunable images, the names
and ages of previews past their TTL, and the release entries that would be trimmed — and ends
with `(dry run — nothing removed; re-run with --confirm to apply)`. Then act:

```bash
nagarectl cleanup --confirm
```

Now it actually prunes the containerd image store (delegating to `crictl rmi --prune`, which by
design protects images referenced by running containers), deletes the stale previews, and rewrites
each release log trimmed to the retention count — printing the space freed and the resources
removed. Re-running `nagarectl cleanup --confirm` immediately afterward is a clean no-op: the
images are already gone, the previews already deleted, the logs already trimmed.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-06-10): Pure `Nagare.Ops.Cleanup` module — the `CleanupOpts`/`CleanupReport`/`ImagePlan`/`PreviewInfo` types, `pruneReleases :: Int -> StaticReleaseLog -> (StaticReleaseLog, [StaticRelease])`, `selectStalePreviews :: UTCTime -> NominalDiffTime -> [PreviewInfo] -> [PreviewInfo]`, the image parsers (`parseCrictlImages`, `sumReclaimableBytes`), and `formatCleanupReport` — added to the cabal library; `testGroup "Nagare.Ops.Cleanup"` (8 cases) covering every selector deterministically (`now`/keep passed in) — all green.
- [x] M2 (2026-06-10): Execution wiring `executeCleanup` (in the library) — the IAP-SSH `crictl` image step (dry-run = `crictl images` via `captureTool`; confirm = `crictl rmi --prune`), the preview-delete step (`kubectl delete ksvc --ignore-not-found` for stale previews matched by the `-pr-` pattern), and the release-trim step (enumerate `nagare-static-releases-*` ConfigMaps, `pruneReleases`, and under `--confirm` `Nagare.Static.Release.writeReleaseLogWith`), all gated behind dry-run/`--confirm`.
- [x] M3 (2026-06-10): `cleanup` command registered in `cli/nagarectl/app/Main.hs` (a single top-level command + `cleanupOptsParser` + `runCleanup` + dispatch arm).
- [x] M4 (2026-06-10): `nagarectl-test` green (171 tests) + `cleanup --help` transcript captured below (`--confirm` off-by-default); dry-run-by-default + degradation proven on an empty PATH (reports `0 / none`, mutates nothing, exit 0); live destructive run deferred (must be exercised against disposable resources).


## Surprises & Discoveries

- 2026-06-10 (M2): Like EP-40, the kubectl/crictl IO had to live in the **library**, not
  `app/Main.hs`, because the `nagarectl` executable has no `cradle` dependency. So `executeCleanup ::
  CleanupOpts -> IO CleanupReport` lives in `Nagare.Ops.Cleanup` and `Main.hs`'s `runCleanup` is a
  two-line `executeCleanup >>= putStr . formatCleanupReport`. Read-only listing reuses EP-38's
  `captureTool` (IP4) so a missing `kubectl`/unreachable VM degrades the category to empty rather than
  crashing; the confirmed deletions use `cradle` `run_` directly.
- 2026-06-10 (M1): `Nagare.Static.Release` was imported **qualified** (`as Rel`) to avoid
  duplicate-record-field clashes — `StaticRelease` exports `namespace`/`image`/`url`/etc., and
  `CleanupOpts` also has a `namespace` field; a bare-selector use would be ambiguous under
  `DuplicateRecordFields`. Qualifying (`Rel.releases`, `Rel.releaseId`, `Rel.current`,
  `Rel.readReleaseLogWith`, `Rel.writeReleaseLogWith`) and using qualified record-update
  (`logv {Rel.releases = …}`) sidesteps it cleanly.
- 2026-06-10 (M2): Previews are discovered generically (any Service whose name contains `-pr-`, with
  `.metadata.creationTimestamp` parsed via `iso8601ParseM`) rather than per-site, since `cleanup` is
  not given a site argument. `selectStalePreviews` stays pure (the `now` is read once in the IO step
  and threaded in), so the staleness rule is unit-tested deterministically.
- 2026-06-10 (M4): Dry-run-by-default verified end to end — on an empty PATH `nagarectl cleanup`
  prints `IMAGES 0 unused`, `PREVIEWS none stale`, `RELEASES none to trim`, the dry-run notice, and
  exits 0, having issued no mutation. The destructive `--confirm` path is exercised live only against
  disposable resources (deferred).


## Decision Log

Record every decision made while working on the plan.

- Decision: `--dry-run` is the default and `--confirm` is required to mutate. Model it as a single
  `--confirm` switch defaulting `False`; "dry run" is simply the *absence* of `--confirm`, so the
  safe behavior is the one you get by typing the least.
  Rationale: This is the only mutating command in MasterPlan 8. A safe-by-default design means an
  operator can always run `nagarectl cleanup` to *understand* what would happen without any risk of
  data loss; deletion is an explicit, deliberate act.
  Date: 2026-06-09

- Decision: Cleanup never deletes a running app's current image, nor any release a Service currently
  points at (the `current` release of every log), nor the most-recent-N releases.
  Rationale: Cleanup reclaims *stale* resources; it must never break a running deployment or remove
  the artifact a live Service or an in-flight rollback depends on.
  Date: 2026-06-09

- Decision: Image prune uses containerd via `crictl` (`sudo k3s crictl rmi --prune`), not docker.
  Rationale: k3s runs on containerd; there is no docker daemon on `nagare-01`, so `docker prune`
  commands are no-ops. `crictl rmi --prune` removes only dangling/unused images and, by design,
  already protects images referenced by running containers — so the current app images are safe
  without nagarectl needing to compute the protected set itself.
  Date: 2026-06-09

- Decision: For v1, the image step *delegates* to `crictl rmi --prune` rather than computing its own
  removal set. Dry-run = run `crictl images` and report counts/sizes; confirm = run the prune.
  Rationale: crictl already implements the correct "unused and unreferenced" policy. Re-implementing
  image-reachability analysis in nagarectl would duplicate containerd logic and risk being wrong;
  delegation is both safer and simpler.
  Date: 2026-06-09

- Decision: Release pruning trims each release log to the most recent N entries (default keep 10),
  never removing the `current` release.
  Rationale: Release history is unbounded-growth metadata in ConfigMaps. Keeping a bounded, recent
  window plus the live release preserves rollback usefulness while reclaiming ConfigMap space.
  Trimming history *only* removes metadata — it never touches a running Service or its image.
  Date: 2026-06-09

- Decision: v1 preview cleanup targets *static-site* previews only (the existing
  `Nagare.Static.Preview` Knative Services); dynamic-app TTL-based preview cleanup is deferred to
  roadmap Phase 7.
  Rationale: Static-site previews exist and are listable/deletable today (EP-15). The dynamic-app
  preview lifecycle is not built, so there is nothing to clean up there yet; scoping v1 to what
  exists keeps the command honest.
  Date: 2026-06-09


## Outcomes & Retrospective

Delivered `nagarectl cleanup`: the pure `Nagare.Ops.Cleanup` module (the
`CleanupOpts`/`CleanupReport`/`ImagePlan`/`PreviewInfo` types, `pruneReleases`,
`selectStalePreviews`, `parseCrictlImages`/`sumReclaimableBytes`, and
`formatCleanupReport`), the library IO `executeCleanup`, and the single
top-level `cleanup` command in `cli/nagarectl/app/Main.hs` (a `Cleanup
CleanupOpts` constructor, `cleanupOptsParser`, `command "cleanup" cleanupCmd`,
`runCleanup`, and the `main` dispatch arm). It is the only mutating command in
MasterPlan 8 and is dry-run-by-default: `--confirm` is required to delete. All
171 tests pass, including the new 8-case `testGroup "Nagare.Ops.Cleanup"`.

Captured transcript (2026-06-10):

```text
$ nagarectl cleanup --help
Usage: nagarectl cleanup [--images] [--previews] [--releases] [--confirm]
                         [--preview-ttl-days N] [--keep-releases N]
                         [-n|--namespace NS]

  Reclaim disk: prune unused images, stale previews, old releases (dry-run by
  default)

Available options:
  --images                 Limit cleanup to the containerd image store
  --previews               Limit cleanup to stale static-site previews
  --releases               Limit cleanup to old release-history entries
  --confirm                REQUIRED to delete; without it cleanup is a dry run
  --preview-ttl-days N     Previews older than N days are stale (default: 7)
  --keep-releases N        Keep the most recent N releases per log (current
                           always kept) (default: 10)
  -n,--namespace NS        Namespace to scan for previews/releases
  -h,--help                Show this help text
```

Dry-run-by-default + degradation (empty PATH — no kubectl/iap-ssh reachable;
reports, mutates nothing, exits 0):

```text
$ PATH=/var/empty nagarectl cleanup
cleanup (dry run)

  IMAGES     0 unused images (~0 B reclaimable)
  PREVIEWS   none stale
  RELEASES   none to trim

(dry run — nothing removed; re-run with --confirm to apply)
$ echo $?
0
```

What changed from the plan: the IO lives in the library (Main.hs is cradle-free),
`Nagare.Static.Release` is imported qualified to dodge field clashes, and previews
are matched generically by the `-pr-` pattern. The destructive `--confirm` live run
(actually pruning images, deleting previews, trimming logs, then a no-op re-run) is
deferred to disposable resources per the plan's M4 convention; the pure selectors,
parsers, and the dry-run/confirmed report shapes are fully unit-tested, and the
dry-run-by-default safety is proven by the empty-PATH run above.


## Context and Orientation

This plan lives entirely in the `cli/nagarectl` package (the CLI). It adds one new pure library
module and one new top-level command; it touches no DSL types and no infrastructure code. You need
to understand four things: how the CLI is structured, what the three cleanup categories actually
are, how the command shells out to its tools, and where the data each category acts on lives.

**The CLI structure.** `cli/nagarectl/app/Main.hs` (~1462 lines) is the entry point and uses
`optparse-applicative`. A sum type `Command` (around line 232) enumerates every operation
(`Deploy`, the `Site*` constructors, the `App*` constructors, the `Deployments*` constructors, …).
`opts :: ParserInfo Command` (around line 540) builds a top-level `subparser` (around line 549)
with `command "deploy" …`, `command "site" …`, `command "env" …`, `command "secret" …`,
`command "app" …`, `command "deployments" …`. `main` (around line 776) does
`execParser opts >>= \case …`, dispatching each constructor to a `runX` handler. To add `cleanup`
you (1) define a `CleanupOpts` record and `cleanupOptsParser :: Parser CleanupOpts`, (2) add a
`Cleanup CleanupOpts` constructor to `Command`, (3) register `command "cleanup" cleanupCmd` in the
top-level `subparser`, (4) add a `runCleanup :: CleanupOpts -> IO ()` handler, and (5) add a
`Cleanup copts -> runCleanup copts` arm in `main`. `cleanup` is a single top-level command (not a
nested group like `site`/`app`). The reusable Main helper you will lean on is `dieT :: Text -> IO a`
(prints `nagarectl: <msg>` to stderr and `exitFailure`). The `--confirm` switch is modeled with
`switch (long "confirm" …)` defaulting `False`, so a plain run is the dry run.

**The three cleanup categories.** Each acts on a different store:

1. *Container images.* k3s uses **containerd**, not docker. The image store lives on the VM boot
   disk (100 GB, shared with `/nix/store`) and is the main disk-pressure source. Listing is
   `sudo k3s crictl images` on the VM; pruning dangling/unused images is `sudo k3s crictl rmi
   --prune`. crictl's own `--prune` already protects images referenced by running containers, so it
   will not remove the current app images. For v1 the image step *delegates* to crictl: dry-run runs
   `crictl images` and reports counts/sizes; `--confirm` runs `crictl rmi --prune`.
2. *Static-site previews.* Static-site previews exist today via
   `cli/nagarectl/src/Nagare/Static/Preview.hs` (created by
   `docs/plans/15-static-release-rollback-and-preview-deployments.md`; commands
   `nagarectl site preview deploy/list/delete` are already in `Main.hs`). A preview is a Knative
   Service named `"<site>-pr-<preview>"` (the `previewPrefix`/`previewServiceName` rules). v1 cleanup
   lists existing preview Services (reusing the `listPreviews` path / `Nagare.Static.Preview`
   helpers — `kubectl get ksvc -o name` filtered to the `<site>-pr-` prefix) and identifies those
   older than a TTL (default 7 days, derived from a creation-timestamp annotation/label on the
   Service) for deletion (reusing the `deletePreview` path under `--confirm`). Dynamic-app preview
   cleanup is **deferred to roadmap Phase 7** and is out of scope here.
3. *Old releases.* Release history is stored in per-subject ConfigMaps.
   `cli/nagarectl/src/Nagare/Static/Release.hs` defines the `StaticReleaseLog` type — a `current ::
   Maybe Text` pointer plus a newest-first `releases :: [StaticRelease]` list — with
   `readReleaseLog`/`writeReleaseLog`/`formatReleasesTable` and the prefix-parameterized
   `readReleaseLogWith`/`writeReleaseLogWith`. Per-app deployment history reuses the same store under
   a different prefix in `cli/nagarectl/src/Nagare/App/Deployments.hs`
   (`docs/plans/31-...`, prefix `"nagare-app-deployments-"`). "Old release pruning" = trim each log
   to the most recent N entries (default keep 10), **never** removing the `current` release. This is
   a *pure* list-trim on the decoded log followed by `writeReleaseLog` of the trimmed result, and is
   the most unit-testable part of the plan.

**How it shells out.** All subprocess calls go through the `cradle` library (already a dependency),
exactly as `cli/nagarectl/src/Nagare/Static/Release.hs` and
`cli/nagarectl/src/Nagare/Static/Preview.hs` do:

```haskell
import Cradle
-- Fire and forget (inherit stdout/stderr); throws on non-zero exit:
run_ $ cmd "kubectl" & addArgs ["delete", "ksvc", T.unpack name, "-n", T.unpack ns, "--ignore-not-found"]
-- Capture stdout, tolerate a non-zero exit:
(exitCode, StdoutRaw out) <- run $ cmd "kubectl" & addArgs ["get", "ksvc", "-n", T.unpack ns, "-o", "json"] & silenceStderr
```

The containerd commands run *on the VM*, reached through `scripts/iap-ssh.sh`. The exact invocation
(matching the access model EP-38 establishes) is, for the dry-run listing:

```bash
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s crictl images'
```

and, under `--confirm`, the prune:

```bash
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s crictl rmi --prune'
```

From Haskell this is a `cradle` call to `cmd "scripts/iap-ssh.sh" & addArgs ["ssh", "nagare-01",
"--", "sudo k3s crictl images"] & setEnv [("SSH_USER","deploy"), ("SSH_KEY", <key>)]`. **If EP-38's
IAP-SSH wrapper helper already exists in the library (e.g. an `iapSsh`/`runOnNode` function in
`Nagare.Ops.*`), reuse it; otherwise replicate the same env + argv pattern locally.**

**Where the data lives.** Images live in containerd on the VM boot disk (reachable only over IAP
SSH, see above). Previews are Knative `ksvc` resources in the site's namespace, named by
`Nagare.Static.Preview.previewServiceName`, with a creation timestamp on the Service
(`.metadata.creationTimestamp`, or a nagare-owned creation annotation if one is set at deploy time).
Release logs are JSON blobs inside ConfigMaps named `"nagare-static-releases-<site>"` (and
`"nagare-app-deployments-<app>"` for apps), read/written by `Nagare.Static.Release`. The aligned-
table pattern to copy is `Nagare.App.formatAppList` with its `pad n t = let t' = T.take n t in t' <>
T.replicate (max 1 (n - T.length t')) " "` helper (also present in
`Nagare.Static.Release.formatReleasesTable`); if EP-38 exposes a shared `pad`/table formatter, reuse
it instead of copying. The test suite is `cli/nagarectl/test/Spec.hs` (`tasty` + `tasty-hunit`),
grouped by module and testing pure helpers only — never the `kubectl`/`crictl` IO.


## Plan of Work

The work is four milestones: the pure selectors and report formatter first (fully unit-tested with
no cluster), then the IO execution wiring, then the command registration, then the green-tests-plus-
help-transcript close. Build everything from `cli/nagarectl` with `cabal build && cabal test`.


### Milestone 1 — Pure `Nagare.Ops.Cleanup` selectors and report


**Scope:** Create `cli/nagarectl/src/Nagare/Ops/Cleanup.hs` containing only pure types and functions —
the option record, the report type, the three selectors, the image-output parsers, and the
formatter. Add the module to `exposed-modules` in `cli/nagarectl/nagarectl.cabal`. Add
`testGroup "Nagare.Ops.Cleanup"` to `cli/nagarectl/test/Spec.hs`. No IO, no `kubectl`, no `crictl`.

The types and signatures to create:

```haskell
module Nagare.Ops.Cleanup
  ( CleanupOpts (..)
  , CleanupReport (..)
  , ImagePlan (..)
  , PreviewInfo (..)
  , defaultPreviewTtlDays
  , defaultKeepReleases
  , pruneReleases
  , selectStalePreviews
  , parseCrictlImages
  , sumReclaimableBytes
  , formatCleanupReport
  ) where

-- | Parsed options for the cleanup command.
data CleanupOpts = CleanupOpts
  { doImages :: !Bool        -- ^ act on the containerd image store
  , doPreviews :: !Bool      -- ^ act on stale static previews
  , doReleases :: !Bool      -- ^ act on old release-log entries
  , confirm :: !Bool         -- ^ REQUIRED to mutate; absent => dry run
  , previewTtlDays :: !Int   -- ^ previews older than this are stale (default 7)
  , keepReleases :: !Int     -- ^ releases kept per log (default 10)
  , namespace :: !(Maybe Text)
  }
  deriving stock (Generic, Show)

-- | One static preview Service and its age inputs.
data PreviewInfo = PreviewInfo
  { previewName :: !Text
  , previewNamespace :: !Text
  , previewCreatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

-- | A parsed containerd image row from `crictl images`.
data ImagePlan = ImagePlan
  { imageRepo :: !Text
  , imageSizeBytes :: !Integer
  }
  deriving stock (Generic, Eq, Show)

-- | What a dry run would do / what a confirmed run did.
data CleanupReport = CleanupReport
  { reportImages :: !(Maybe (Int, Integer))   -- ^ (count, reclaimable bytes) or Nothing if not scanned
  , reportStalePreviews :: ![PreviewInfo]
  , reportTrimmedReleases :: ![(Text, [StaticRelease])]  -- ^ (logSubject, removed entries)
  , reportConfirmed :: !Bool
  }
  deriving stock (Generic, Show)

defaultPreviewTtlDays :: Int
defaultPreviewTtlDays = 7

defaultKeepReleases :: Int
defaultKeepReleases = 10
```

The three pure selectors, each with `now` (or the retention count) passed in so tests are
deterministic:

```haskell
-- | Trim a release log to the most recent @keep@ entries, NEVER removing the
-- @current@ release. Returns the trimmed log and the entries that were removed.
-- Records are already newest-first (see 'Nagare.Static.Release.addRelease'); we
-- keep the first @keep@ plus the @current@ record wherever it sits, and report
-- the rest as removed.
pruneReleases :: Int -> StaticReleaseLog -> (StaticReleaseLog, [StaticRelease])

-- | Given the wall-clock @now@, a TTL, and the previews discovered in-cluster,
-- return those whose age exceeds the TTL (i.e. should be deleted).
selectStalePreviews :: UTCTime -> NominalDiffTime -> [PreviewInfo] -> [PreviewInfo]

-- | Parse `crictl images` (or `crictl images -o json`) output into rows.
parseCrictlImages :: ByteString -> [ImagePlan]

-- | Total reclaimable bytes across a list of parsed image rows.
sumReclaimableBytes :: [ImagePlan] -> Integer

-- | Render the cleanup report as an aligned, human-readable block; the closing
-- line is the dry-run notice unless @reportConfirmed@ is True.
formatCleanupReport :: CleanupReport -> Text
```

The contract that must hold (and that the tests pin down): `pruneReleases` keeps `current` even when
it is older than the Nth entry; `selectStalePreviews` is a pure function of `(now, ttl, list)` with
no `getCurrentTime`; `parseCrictlImages` tolerates blank/header lines; `formatCleanupReport`'s last
line is the dry-run notice when `reportConfirmed == False`.

Reuse `StaticRelease`/`StaticReleaseLog` from `Nagare.Static.Release` (import, do not redefine) and
the `pad` table helper (copy verbatim, or reuse EP-38's shared `pad` if present).

The test group `testGroup "Nagare.Ops.Cleanup" cleanupTests` in `cli/nagarectl/test/Spec.hs` covers:
`pruneReleases` keeps `current` + last N and returns the removed list (including the case where
`current` is the oldest record); `selectStalePreviews` picks exactly the entries past a fixed TTL
given a fixed `now`; `parseCrictlImages` + `sumReclaimableBytes` on a fixture; and
`formatCleanupReport` ending in the dry-run notice vs. the confirmed summary.

**Acceptance:** `cd cli/nagarectl && cabal build && cabal test` passes with the new `Nagare.Ops.Cleanup`
group green; no IO is exercised.


### Milestone 2 — Execution wiring (dry-run / confirm)


**Scope:** Add the small IO layer that gathers inputs and, under `--confirm`, performs the three
deletions. This can live as a `runCleanupWith` helper in `Main.hs` or as IO functions in a separate
`Nagare.Ops.Cleanup` IO section; keep the *pure* selectors in M1 untouched. Wire:

- *Images.* Dry run: shell `scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s crictl images'`
  (env `SSH_USER=deploy`, `SSH_KEY=~/.ssh/id_ed25519`), capture stdout, `parseCrictlImages` it,
  `sumReclaimableBytes` for the report. Confirm: shell
  `scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s crictl rmi --prune'`. Tolerate a non-zero exit /
  unreachable VM by degrading the image line to "unreachable" rather than crashing. Reuse EP-38's
  IAP-SSH wrapper if present:

  ```haskell
  -- Dry-run listing on the VM:
  (ec, StdoutRaw out) <-
    run $ cmd "scripts/iap-ssh.sh"
      & addArgs ["ssh", "nagare-01", "--", "sudo k3s crictl images"]
      & setEnv [("SSH_USER", "deploy"), ("SSH_KEY", keyPath)]
      & silenceStderr
  -- Confirm: same wrapper, args ["ssh","nagare-01","--","sudo k3s crictl rmi --prune"].
  ```

- *Previews.* List with `Nagare.Static.Preview.listPreviews site ns` (or a direct `kubectl get ksvc
  -n <ns> -o json` to also read `.metadata.creationTimestamp`), build `[PreviewInfo]`, run
  `selectStalePreviews now ttl`. Confirm: for each stale preview call
  `Nagare.Static.Preview.deletePreview ns serviceName domain` (which already passes
  `--ignore-not-found`, so a repeated delete is a clean no-op).

- *Releases.* For each release log in scope, `readReleaseLog`/`readReleaseLogWith`, run
  `pruneReleases keep`, and under `--confirm` `writeReleaseLog`/`writeReleaseLogWith` the trimmed
  log. A malformed/unreadable log is reported and skipped, never overwritten.

The dispatcher assembles a `CleanupReport` and prints `formatCleanupReport`. Under dry run nothing
is written; under `--confirm` the report reflects what was removed and `reportConfirmed = True`.

**Acceptance:** `cabal build` is clean; with `--confirm` absent the wiring performs only read-only
listing (`crictl images`, `kubectl get ksvc`, `kubectl get configmap`) and writes nothing. (The
mutating path is exercised live only against disposable resources — see Validation.)


### Milestone 3 — Register the `cleanup` command


**Scope:** Edit `cli/nagarectl/app/Main.hs`. Add `cleanupOptsParser :: Parser CleanupOpts` (the
`--images`/`--previews`/`--releases`/`--confirm`/`--preview-ttl-days`/`--keep-releases`/`-n`
switches, `--confirm` defaulting `False`), a `Cleanup CleanupOpts` constructor on `Command` (around
line 232), `command "cleanup" cleanupCmd` appended to the top-level `subparser` (around line 549 —
Integration Point IP3; append in EP-38's style, do not remove other commands), a `runCleanup`
handler, and a `Cleanup copts -> runCleanup copts` arm in `main` (around line 776).

```haskell
cleanupOptsParser :: Parser CleanupOpts
cleanupOptsParser =
  CleanupOpts
    <$> switch (long "images" <> help "Limit cleanup to the containerd image store")
    <*> switch (long "previews" <> help "Limit cleanup to stale static-site previews")
    <*> switch (long "releases" <> help "Limit cleanup to old release-history entries")
    <*> switch (long "confirm" <> help "REQUIRED to delete; without it cleanup is a dry run")
    <*> option auto (long "preview-ttl-days" <> value defaultPreviewTtlDays <> showDefault <> metavar "N")
    <*> option auto (long "keep-releases" <> value defaultKeepReleases <> showDefault <> metavar "N")
    <*> optional (strOption (long "namespace" <> short 'n' <> metavar "NS"))

cleanupCmd :: ParserInfo Command
cleanupCmd =
  info
    (Cleanup <$> cleanupOptsParser <**> helper)
    (fullDesc <> progDesc "Reclaim disk: prune unused images, stale previews, old releases (dry-run by default)")
```

When none of `--images/--previews/--releases` is given, `runCleanup` treats all three as selected
(the "act on all three" default); any of them narrows the scope. `--confirm` is still required to
delete in every case.

**Acceptance:** `cabal build` is clean; `cabal run nagarectl -- cleanup --help` prints the command
with all flags and shows `--confirm` as off-by-default.


### Milestone 4 — Tests green + `--help` transcript; live run deferred


**Scope:** Run the full suite, capture the `cleanup --help` transcript into Concrete Steps, and
record in Progress that the destructive live run is deferred to disposable resources. No code change
beyond fixups the suite surfaces.

**Acceptance:** `cd cli/nagarectl && cabal build && cabal test` is fully green; the
`cleanup --help` transcript is pasted below; Progress M4 is checked with the note "tests green +
--help transcript; live destructive run deferred."


## Concrete Steps

All build/test commands run from the CLI package directory:

```bash
cd cli/nagarectl && cabal build && cabal test
```

After M3, confirm the command exists and is dry-run by default:

```bash
cd cli/nagarectl && cabal run nagarectl -- cleanup --help
```

Expected output shape (exact wording will vary; the load-bearing parts are the flags and that
`--confirm` is off by default):

```text
Usage: nagarectl cleanup [--images] [--previews] [--releases] [--confirm]
                         [--preview-ttl-days N] [--keep-releases N]
                         [-n|--namespace NS]

  Reclaim disk: prune unused images, stale previews, old releases (dry-run by default)

Available options:
  --images                 Limit cleanup to the containerd image store
  --previews               Limit cleanup to stale static-site previews
  --releases               Limit cleanup to old release-history entries
  --confirm                REQUIRED to delete; without it cleanup is a dry run
  --preview-ttl-days N     (default: 7)
  --keep-releases N        (default: 10)
  -n,--namespace NS
  -h,--help                Show this help text
```

The end-to-end dry-run, then confirmed, narrative (run with `kubectl` pointed at the k3s cluster and
`scripts/iap-ssh.sh` able to reach `nagare-01`):

```bash
# 1. Dry run (default): reports, removes nothing.
cabal run nagarectl -- cleanup

# 2. Apply: actually prunes images, deletes stale previews, trims release logs.
cabal run nagarectl -- cleanup --confirm

# 3. Re-run --confirm: a clean no-op (everything already gone).
cabal run nagarectl -- cleanup --confirm
```

Expected dry-run output shape:

```text
cleanup (dry run)

  IMAGES     12 unused images reclaimable (~3.4 GiB)
  PREVIEWS   2 stale (> 7d):
               notes-pr-fix-typo        9d
               notes-pr-old-experiment  21d
  RELEASES   notes: 4 entries beyond keep=10 would be trimmed (current kept)

(dry run — nothing removed; re-run with --confirm to apply)
```

Expected confirmed output shape:

```text
cleanup (applied)

  IMAGES     pruned via crictl rmi --prune (~3.4 GiB reclaimed)
  PREVIEWS   deleted 2 stale previews: notes-pr-fix-typo, notes-pr-old-experiment
  RELEASES   notes: trimmed 4 entries (kept current + most recent 10)

done.
```

This section is updated with the captured `cleanup --help` transcript at M4.


## Validation and Acceptance

Exercise the system as follows and observe the stated behavior:

1. **Pure release trimming.** `cd cli/nagarectl && cabal test`. The `Nagare.Ops.Cleanup` group asserts
   that `pruneReleases 10 log` on a 14-entry log returns a 10-entry log plus a 4-entry removed list,
   and — the safety case — that with `current` set to the *oldest* record, `pruneReleases 3` keeps
   `current` even though it falls outside the most-recent-3 window, and never lists it as removed.

2. **Pure preview staleness.** With a fixed `now = 2026-06-09T00:00:00Z`, a 7-day TTL, and three
   `PreviewInfo` with ages 1d / 9d / 21d, `selectStalePreviews now (7*86400) xs` returns exactly the
   9d and 21d entries. Changing `now` deterministically changes the result; no `getCurrentTime` is
   called inside the selector.

3. **Pure image parsing.** `parseCrictlImages` on a `crictl images` fixture returns the expected
   rows (skipping the header/blank lines), and `sumReclaimableBytes` sums their sizes.

4. **Pure report formatting.** `formatCleanupReport` on a report with `reportConfirmed = False` ends
   with the dry-run notice line; with `reportConfirmed = True` it ends with the confirmed summary and
   contains no dry-run notice.

5. **Command surface.** `cabal run nagarectl -- cleanup --help` lists every flag and shows
   `--confirm` as a switch (off by default), confirming dry-run-by-default at the parser level.

6. **Dry run removes nothing (live, read-only).** Against a real cluster, `cabal run nagarectl --
   cleanup` performs only `crictl images`, `kubectl get ksvc`, and `kubectl get configmap` reads and
   writes nothing — verify by re-reading a release ConfigMap and a preview list before and after and
   observing they are unchanged.

7. **Confirmed run reclaims and is idempotent (live, destructive).** Against *disposable* resources,
   `cabal run nagarectl -- cleanup --confirm` prunes images, deletes the stale previews, and trims
   the logs; a second `--confirm` run is a clean no-op (already-gone resources are not errors).

If no cluster is reachable, items 6–7 are validated by unit tests on the pure selectors/formatters;
the live destructive run is deferred and must be done against disposable resources.


## Idempotence and Recovery

Safety is the defining property of this command, so the whole design is built around it.

**Dry run is the default.** Running `nagarectl cleanup` with no flags removes nothing — it only
reads and reports. There is no way to delete by accident; deletion requires the explicit `--confirm`
flag. An operator can always run the command to *understand* the situation at zero risk.

**Every deletion is individually safe to re-run.** The three confirmed operations are each
idempotent:

- *Images.* `crictl rmi --prune` removes only dangling/unused images and protects anything a running
  container references; running it again when there is nothing to prune is a no-op, and it can never
  remove a current app's running image.
- *Previews.* `Nagare.Static.Preview.deletePreview` passes `--ignore-not-found` for both the Service
  and the DomainMapping, so deleting an already-gone preview is a clean no-op, not an error.
- *Releases.* Trimming is a pure rewrite of the log to its most-recent-N (plus `current`) entries;
  applying it twice produces the same log the second time, and it never removes the `current`
  release nor any of the most-recent-N.

**The cuts are reversible or harmless.** Pruned images are re-pullable from the Artifact Registry on
the next deploy — they are a cache, not a source of truth. Pruned release-log entries only trim
*history metadata*; they do not touch any running Service, its revision, or its image, so a trimmed
log never affects what is serving traffic (only how far back the rollback list reaches). Deleted
stale previews are non-production by definition and can be re-created with
`nagarectl site preview deploy`.

**Recover from a bad edit with `git checkout`.** All changes in this plan are source edits under
`cli/nagarectl/`; if a milestone goes wrong, `git checkout -- cli/nagarectl/` (or revert the commit)
restores the prior state. The CLI itself never edits source — its only writes are the cluster-side
deletions above, which are themselves idempotent and reversible as described.


## Interfaces and Dependencies

**Libraries and modules to use.** `cradle` (already a dependency) for every subprocess call —
`kubectl`, `crictl` over `scripts/iap-ssh.sh`; `aeson`/`bytestring`/`text`/`time` (all already in
the library `build-depends`) for parsing and selectors. Reused in-repo modules:
`cli/nagarectl/src/Nagare/Static/Release.hs` (the `StaticRelease`/`StaticReleaseLog` types and
`readReleaseLog`/`writeReleaseLog`/`readReleaseLogWith`/`writeReleaseLogWith`/`formatReleasesTable`),
`cli/nagarectl/src/Nagare/Static/Preview.hs` (`listPreviews`, `deletePreview`,
`previewServiceName`/`previewPrefix`), and
`cli/nagarectl/src/Nagare/App/Deployments.hs` (the app-history store under prefix
`"nagare-app-deployments-"`, if app release logs are trimmed too). No new package dependency is
needed; the new `Nagare.Ops.Cleanup` module only needs what the library already has.

**Soft reuse of EP-38 helpers.** This plan soft-depends on
`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md`: if EP-38 has landed a
shared IAP-SSH wrapper (a function that shells `scripts/iap-ssh.sh` with `SSH_USER=deploy`,
`SSH_KEY=~/.ssh/id_ed25519`) and a shared `pad`/aligned-table formatter in `Nagare.Ops.*`, reuse
them for the `crictl` calls and the cleanup report. If EP-38 has not landed, replicate the same
patterns locally (the `setEnv` + argv shape shown in the Plan of Work, and the `pad` helper copied
from `Nagare.App.formatAppList` / `Nagare.Static.Release.formatReleasesTable`). This plan does **not**
need EP-38's probe-grading model (`ProbeStatus`/`Probe`) — only the SSH wrapper and table pad.

**Signatures that must exist** at the end of M1 (pure) and through M3 (command):

```haskell
-- M1 — pure, in cli/nagarectl/src/Nagare/Ops/Cleanup.hs:
pruneReleases       :: Int -> StaticReleaseLog -> (StaticReleaseLog, [StaticRelease])
selectStalePreviews :: UTCTime -> NominalDiffTime -> [PreviewInfo] -> [PreviewInfo]
parseCrictlImages   :: ByteString -> [ImagePlan]
sumReclaimableBytes :: [ImagePlan] -> Integer
formatCleanupReport :: CleanupReport -> Text
defaultPreviewTtlDays :: Int   -- 7
defaultKeepReleases   :: Int   -- 10

-- M3 — command, in cli/nagarectl/app/Main.hs:
cleanupOptsParser :: Parser CleanupOpts
runCleanup        :: CleanupOpts -> IO ()
-- plus the `Cleanup CleanupOpts` constructor on `Command` and the
-- `command "cleanup" cleanupCmd` registration in the top-level subparser.
```

**Integration.** The cleanup command appends to the top-level `subparser` in
`cli/nagarectl/app/Main.hs` (MasterPlan 8 Integration Point IP3 — the shared command-registration
block); it adds `command "cleanup" cleanupCmd` alongside `deploy`/`site`/`env`/`secret`/`app`/
`deployments` without removing any of them, in the same style EP-38 uses to add its `server` group.
It reuses the access model and (if present) the helpers from
`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md`. The downstream consumer
is `nagarectl doctor` (`docs/plans/39-nagarectl-doctor-health-checks-with-remediation-hints.md`):
when doctor grades the disk-usage probe as full, its remediation hint points the operator at
`nagarectl cleanup` (dry run first, then `--confirm`) as the fix — so `cleanup` is the action that
closes doctor's disk-pressure check.
