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

Full plan before trimming: [31-application-deployment-history-and-deployments-commands.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/31-application-deployment-history-and-deployments-commands.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] M1: per-app deployment history store (reuse/generalize `Nagare.Static.Release`) with pure-layer unit tests. (2026-06-10)
- [x] M2: `runDeploy` records a deployment on success (non-fatal); `--source` added to app `deploy` and surfaced as `NAGARE_SOURCE`. (2026-06-10)
- [x] M3: `deployments list NAME` prints the table; `deployments logs NAME [ID]` streams logs (id → revision via `resolveRevisionForTag`). (2026-06-10)
- [x] M4: `nagarectl-test` green (106); `--help` transcripts captured below; live cluster run deferred (no cluster mutated), as M4 permits. (2026-06-10)

## Surprises & Discoveries

- **EP-30 had already landed**, so `Nagare.App` (`cli/nagarectl/src/Nagare/App.hs`) already provided
  `LogTarget`/`streamServiceLogs`/`appIdentityOrDie` with the exact IP2 signatures — this plan reused
  them directly (no fallback creation needed). The `app delete` path already removes the
  `nagare-app-deployments-<app>` ConfigMap, which matches the name `Nagare.App.Deployments.appConfigMapName`
  produces, so the two halves of IP3 agree with no coordination needed. (2026-06-10)

- **Generalization approach (a) was clean.** Parameterizing `Nagare.Static.Release` by a ConfigMap-name
  prefix (`configMapNameWith`/`renderReleaseConfigMapWith`/`readReleaseLogWith`/`writeReleaseLogWith`/
  `recordReleaseForWith`) and making the original functions thin wrappers fixing
  `"nagare-static-releases-"` left static behaviour byte-identical — all pre-existing
  `Nagare.Static.Release` tests pass unchanged — and `Nagare.App.Deployments` is a ~30-line wrapper
  supplying the app prefix. Approach (b) (wholesale copy) was not needed. (2026-06-10)

- **Deployment id vs. prebuilt-image revision matching.** The recorded deployment id is the resolved
  `imageTag` (= `NAGARE_RELEASE_ID`, = `--tag`), for consistency with the static `releaseId` and the
  generated env. For Dockerfile/Nixpacks builds the deployed image carries that same tag, so
  `deployments logs NAME <id>` resolves the revision by matching `:<id>` on the revision's image. For a
  *prebuilt* image the running image carries the prebuilt's own tag (not the deploy id), so
  `resolveRevisionForTag` will not find a revision and the command reports the clear "no live revision
  for deployment <id>" message — `deployments logs NAME` (live) always works. Recorded in the Decision
  Log. (2026-06-10)

- **Live cluster run deferred** (same rationale as EP-30): creating real Knative Services / ConfigMaps
  in `tan-nb-exp` is outward-facing and not required to implement the plan. The pure helpers
  (`addRelease` reuse, table formatting, `revisionForTag` id→revision matcher) are unit-tested and the
  command surfaces verified via `--help`; the end-to-end live transcript is left for a follow-up.
  (2026-06-10)

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

- Decision: Record the deployment id as the resolved `imageTag` (not the build-spec-resolved `effTag`),
  for consistency with the static `releaseId`, `NAGARE_RELEASE_ID`, and the `--tag` the user passes.
  Consequence accepted: for a *prebuilt-image* deploy the running revision's image carries the
  prebuilt's own tag rather than `imageTag`, so `deployments logs NAME <id>` cannot resolve that
  revision and reports the clear garbage-collected-style message; the live `deployments logs NAME`
  always works. Dockerfile/Nixpacks builds (the common path) are unaffected because their deployed
  image *is* tagged with `imageTag`.
  Rationale: A single, predictable deployment id that matches every other place the tag appears beats a
  per-build-mode id scheme. The prebuilt edge case degrades to a clear message, not silent failure.
  Date: 2026-06-10

- Decision: Generalize `Nagare.Static.Release` via prefix-parameterized `*With` functions (approach
  (a) from the Plan of Work), keeping the original functions as wrappers that fix the static prefix, so
  static behaviour and tests are unchanged; `Nagare.App.Deployments` wraps them with the
  `"nagare-app-deployments-"` prefix.
  Rationale: One implementation, one set of tests, byte-identical static behaviour; the app store is a
  thin, obviously-correct wrapper. Approach (b) (wholesale copy) was unnecessary.
  Date: 2026-06-10

## Outcomes & Retrospective

Completed 2026-06-10. `cli/nagarectl` builds and `nagarectl-test` is green (106 tests).

What exists now that did not before:

- `Nagare.Static.Release` generalized with prefix-parameterized `configMapNameWith`/
  `renderReleaseConfigMapWith`/`readReleaseLogWith`/`writeReleaseLogWith`/`recordReleaseForWith`; the
  original functions are wrappers fixing `"nagare-static-releases-"` (static behaviour byte-identical).
- `cli/nagarectl/src/Nagare/App/Deployments.hs` — the per-app history store reusing that layer under
  `"nagare-app-deployments-"`: `appConfigMapName`, `readDeployments`, `writeDeployments`,
  `recordDeploymentFor`, `findDeployment`, `formatDeploymentsTable`, plus `resolveRevisionForTag` and
  its pure core `revisionForTag`.
- `nagarectl deploy` now records a deployment on success (non-fatal) and carries `--source`
  (surfaced as `NAGARE_SOURCE`, matching the site path).
- Two new commands: `nagarectl deployments list NAME` (history table, live deployment starred) and
  `nagarectl deployments logs NAME [DEPLOYMENT_ID]` (live revision logs, or a past deployment's
  revision resolved by image tag).
- 4 new unit tests (`appConfigMapName`, `revisionForTag` match/no-match/malformed).

Verification: `cabal test` green (static tests unchanged, proving no regression); `--help`
transcripts in Concrete Steps. Live cluster run deferred (no cluster mutated) per M4.

Integration confirmed: the history ConfigMap name `nagare-app-deployments-<app>` matches the name
`nagarectl app delete` (EP-30) already removes, and the `deployments logs` revision path reuses
`Nagare.App.streamServiceLogs`/`LogTarget` from EP-30 — IP2 and IP3 satisfied with no re-derivation.

