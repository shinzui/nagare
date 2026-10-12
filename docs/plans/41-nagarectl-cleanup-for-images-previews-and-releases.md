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

Full plan before trimming: [41-nagarectl-cleanup-for-images-previews-and-releases.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/41-nagarectl-cleanup-for-images-previews-and-releases.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

