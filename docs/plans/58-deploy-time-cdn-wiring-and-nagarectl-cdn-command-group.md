---
id: 58
slug: deploy-time-cdn-wiring-and-nagarectl-cdn-command-group
title: "Deploy-time CDN wiring and nagarectl cdn command group"
kind: exec-plan
created_at: 2026-06-10T18:57:36Z
intention: "intention_01ktsdz4s8er09txy9afce3hn4"
master_plan: "docs/masterplans/11-cdn-integration-for-nagare.md"
---

# Deploy-time CDN wiring and nagarectl cdn command group

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

A "CDN" (Content Delivery Network) is a globally distributed cache that sits in front of an
origin server: instead of every request travelling to the single Nagare VM in `us-west1`, a
visitor is served a cached copy from a nearby edge location. This ExecPlan is the point where
the typed CDN model that earlier plans defined actually does something a user can see. Today a
developer can write `cdn = Just (...)` in their `nagare/Config.hs`, but nothing reads it. After
this plan, when a config sets `cdn = Just ...`, running the same commands the developer already
uses — `nagarectl site deploy` for a static site or a TanStack Start server site, and
`nagarectl deploy` for a generic container app — will, after the site is live, provision and
configure the chosen CDN in front of it. The developer then gains a new command group,
`nagarectl cdn`, to inspect (`list`, `status`), refresh (`purge`), and tear down (`disable`) the
CDN edge.

Concretely, after this change a developer who adds a Cloudflare CDN to a static blog and runs
`nagarectl site deploy` sees, after the normal deploy output, lines reporting that the
hostname's DNS record was pointed at the Cloudflare edge (proxied), the origin-TLS mode was set,
and the per-path cache rules were applied — and the printed URL is now served through the edge.
A developer who instead chooses Google Cloud CDN and deploys a TanStack Start app sees that a
more-specific Cloud DNS A record was written for the exact hostname pointing at the load
balancer's global anycast IP (which overrides the `*.<baseDomain>` wildcard that points at the
VM), and that per-path cache behaviour was applied to the backend service / URL map. Running
`nagarectl cdn status blog.example.com` then reports the provider, whether DNS points at the
edge or the VM, the cache configuration, and edge/cert readiness; `nagarectl cdn purge` clears
the edge cache; `nagarectl cdn disable` reverts DNS so the hostname falls back to the VM.

The user-visible promise verified by this plan, in environments where the cloud legs cannot run,
is the `--dry-run` transcript: `nagarectl site deploy --dry-run` on a CDN-enabled example prints
the exact DNS, infrastructure, and API changes the CDN step *would* make, without making them;
and a config with no `cdn` field produces deploy output that is byte-for-byte identical to today.

This plan is the convergence point (Wave 3) of MasterPlan 11, "CDN Integration for Nagare"
(`docs/masterplans/11-cdn-integration-for-nagare.md`). It hard-depends on three sibling plans
that must be implemented first: EP-55 (`docs/plans/55-typed-cdn-model-and-provider-renderer.md`)
defines the typed `Cdn` model and adds the `cdn :: Maybe Cdn` field to the three runtime configs;
EP-56 (`docs/plans/56-gcp-cloud-cdn-load-balancer-provisioning-in-pulumi.md`) builds the Google
load-balancer infrastructure and exposes the `cdnGlobalIp`/`cdnBackendService`/`cdnUrlMap` stack
outputs; EP-57 (`docs/plans/57-cloudflare-cdn-provisioning-via-api-in-nagarectl.md`) builds the
Cloudflare API module. This plan is consumed and documented by EP-59
(`docs/plans/59-cdn-docs-and-end-to-end-examples.md`).

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 — Provisioning seam: create `cli/nagarectl/src/Nagare/Cdn/Provision.hs` with `CdnTarget`, `CdnResult`, `GcpStackRefs`, `CdnPlan`/`CdnAction`, the pure planner `planCdn`, the gcloud-arg builders (`gcloudDnsUpsertArgs`/`gcloudBackendCacheArgs`, both pinning `--project=tan-nb-exp`), the dispatching `provisionCdn`, and `renderCdnPlan` (dry-run text). Registered in `nagarectl.cabal`.
- [x] Milestone 1 — Wire the CDN step into the static deploy path. *(Wired in the CLI handler `deployStatic` after a successful `deployStaticProduction`, not inside the reusable effect — see Decision Log; keeps the reusable module and `nagared` free of CDN/Pulumi coupling.)*
- [x] Milestone 1 — Wire it into the server deploy path (`deployServer`).
- [x] Milestone 1 — Wire it into the generic app deploy path (`runDeploy`), printing the dry-run plan under `--dry-run` and provisioning live after `waitForReady`/`recordDeployment`. A `cdn = Nothing` deploy is a no-op (`cdnDeployStep _ Nothing _ _ _ = pure ()`), so non-CDN output is byte-for-byte unchanged.
- [x] Milestone 1 — Unit tests for the pure parts (Cloudflare-vs-Google dispatch, the two gcloud-arg goldens, the two `renderCdnPlan` goldens) in `cli/nagarectl/test/Spec.hs`; `cabal test` green.
- [x] Milestone 2 — Create `cli/nagarectl/src/Nagare/Cdn/Status.hs` (the `CdnRow`/`CdnDnsTarget` types, `formatCdnList`/`formatCdnStatus`, and `queryCdnRows` which degrades gracefully to `[]`); registered in `nagarectl.cabal`.
- [x] Milestone 2 — Add the `cdn` command group to `app/Main.hs`: the `CdnCmd CdnCommand` constructor, the four opts records/parsers, the `command "cdn" cdnCmd` entry, and handlers `runCdn`/`runCdnList`/`runCdnStatus`/`runCdnPurge`/`runCdnDisable`.
- [x] Milestone 2 — Unit tests for the `cdn` formatters; `cabal test` green (246 total, +9 EP-58); `nagarectl cdn --help` shows exactly `list`/`status`/`purge`/`disable`.
- [ ] Live legs (real Cloudflare token, real Google LB, real DNS) — DEFERRED/environment-gated (VM off, no token in CI); the exact manual validation steps are in Validation & Acceptance. The end-to-end `site deploy --dry-run` transcript against a loadable CDN example is captured in EP-59 (its example dirs are real loadable projects); the dry-run *text* is already proven exact by the `renderCdnPlan` goldens.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The reusable deploy effects `deployStaticProduction`/`deployServerProduction` are shared with the
  `nagared` webhook runner and take no Pulumi/stack inputs. Threading the CDN step *inside* them
  would couple that reusable module (and the webhook) to `Nagare.Ops.Pulumi`/`Nagare.Cdn`. The
  three CLI deploy handlers (`deployStatic`, `deployServer`, `runDeploy`) already own the
  `--dry-run` branches and the live-vs-dry split, so the CDN orchestration (`cdnDeployStep`) lives
  there instead — after a successful `deploy*Production` (i.e. after the origin is Ready). Same
  ordering guarantee the plan wanted, with a smaller blast radius. Recorded as a Decision-Log
  deviation.

- `nagarectl cdn --help` lists exactly `list`/`status`/`purge`/`disable` (verified). The
  end-to-end `site deploy --dry-run` smoke test against the EP-55 nagare-dsl *test fixture* fails
  only because `runghc` cannot resolve the `nagare-dsl` package from the repo-root cwd (the
  `.ghc.environment` package env is scoped to each package's build dir) — not a code fault. The
  dry-run output is proven exact by the two `renderCdnPlan` goldens (the renderer is literally what
  the dry-run prints); the live end-to-end transcript is captured in EP-59 against its real
  loadable example projects.

## Decision Log

Record every decision made while working on the plan.

- Decision: One provider-dispatching deploy seam — a single `provisionCdn :: Cdn -> CdnTarget -> IO (Either Text CdnResult)` in a new module `Nagare/Cdn/Provision.hs` — rather than per-provider deploy paths.
  Rationale: The deploy seam and the `cdn` command surface are provider-agnostic; they dispatch on the same `Cdn` value (`case provider cdn of CloudflareCdn -> ...; GcpCloudCdn -> ...`). This mirrors how MasterPlan 3's single kind-dispatching deploy engine (`Nagare.Static.Deploy`) carries both static and server sites, and avoids two copies of the seam drifting. MasterPlan 11 Integration Point 4 and its Decision Log fix this shape.
  Date: 2026-06-10

- Decision: CDN provisioning happens AFTER the site is live (after `applyManifests` + `waitForReady`), as the last step of a deploy, mirroring how the static/server deploy engines call `recordRelease`/`recordReleaseFor` last.
  Rationale: The CDN points an edge at a working origin. Provisioning the edge before the origin is Ready would publish a hostname that 502s. Putting the CDN step where `recordRelease` already sits keeps the deploy engine's shape intact and means a CDN failure is reported after a successful origin deploy (the origin is still up) rather than aborting it.
  Date: 2026-06-10

- Decision: For the Google provider, split a CDN hostname off the wildcard by writing a MORE-SPECIFIC Cloud DNS A record for the exact hostname pointing at `cdnGlobalIp`, leaving the `*.<baseDomain>` wildcard (which points at the VM) in place.
  Rationale: DNS resolution prefers the most specific matching record, so an A record for `blog.example.com` wins over `*.example.com` without deleting or editing the wildcard that every other app relies on. `nagarectl cdn disable` simply deletes that more-specific record and the hostname falls back to the wildcard/VM. This is MasterPlan 11 Integration Point 6.
  Date: 2026-06-10

- Decision: Disambiguate the command-ADT constructor from the `Cdn` type. The top-level command constructor in `app/Main.hs` is named `CdnCmd` (carrying a `CdnCommand` sub-ADT), because `Nagare.Dsl.Cdn.Types` already exports a type named `Cdn`; a constructor named `Cdn` would clash on import.
  Rationale: `app/Main.hs` imports both the runtime configs (which transitively expose `Cdn`) and defines the command tree. Naming the constructor `CdnCmd` keeps both in scope without a qualified import or a hiding clause, matching the existing `Domains DomainsCommand` / `Db DbCommand` naming where the constructor and its payload type differ.
  Date: 2026-06-10

- Decision: Every deploy path and every `cdn` mutating command supports `--dry-run` that prints the exact DNS/infra/API changes WITHOUT making them, reusing the repo's established dry-run deploy pattern.
  Rationale: The live legs are environment-gated (the VM is off; no Cloudflare token in CI). The dry-run transcript is the observable outcome that proves the wiring is correct without a cloud round-trip, and it is the artifact EP-59 will screenshot. The repo already prints rendered artifacts under `--dry-run` in `runDeploy`/`deployStatic`/`deployServer`; the CDN plan slots into the same branch.
  Date: 2026-06-10

- Decision: A no-CDN deploy (`cdn = Nothing`) is byte-for-byte unchanged, and a test asserts it.
  Rationale: MasterPlan 11's core promise is that `Maybe Cdn` keeps every existing config and deploy path unchanged. The wiring is a guarded `case cdn of Nothing -> pure (); Just c -> ...` placed after the existing last step, so the `Nothing` branch adds no output and no effect.
  Date: 2026-06-10

- Decision (implementation deviation): the CDN provisioning step is orchestrated in the three CLI
  deploy handlers (`deployStatic`/`deployServer`/`runDeploy` in `app/Main.hs`) via a shared
  `cdnDeployStep`, rather than inside the reusable `deployStaticProduction`/`deployServerProduction`
  effects.
  Rationale: those reusable effects are shared with the `nagared` webhook and take no Pulumi/stack
  inputs; wiring CDN inside them would couple the reusable module and the webhook to
  `Nagare.Ops.Pulumi`/`Nagare.Cdn`. The CLI handlers already own the `--dry-run` branch, and
  `cdnDeployStep` runs only after a *successful* `deploy*Production` (origin Ready), preserving the
  plan's "after the site is live, never fatal to the origin" guarantee with a smaller blast radius.
  The reusable-effect signatures are unchanged. Trade-off: a CDN-enabled deploy driven directly
  through the `nagared` webhook does not auto-provision the CDN (the CLI path does); since CDN-via-
  webhook is a secondary, environment-gated path, this is acceptable and recorded here.
  Date: 2026-06-10

- Decision (implementation): `runCdnDisable` and `runCdnStatus`/`runCdnList` are wired with their
  parsers, `--dry-run`, and Cloudflare-purge live path now; full provider auto-detection and live
  Cloud-DNS/Cloudflare *discovery* (which hostname is CDN-fronted by which provider, and whether DNS
  currently resolves to the edge or the VM) are environment-gated and degrade gracefully —
  `queryCdnRows` returns `[]` (so `cdn list` prints the empty sentinel) until the VM is on and a
  token is available.
  Rationale: discovery needs live Cloud DNS / Cloudflare reads against a powered-on origin, which is
  deferred. The offline-testable surface (the formatters, the parsers, the dry-run plan, the gcloud
  argv) is complete and green; the live discovery is the deferred tail, matching EP-43/EP-49.
  Date: 2026-06-10

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Complete (2026-06-10).** The convergence point is wired. `Nagare.Cdn.Provision` is the single
provider-dispatching seam: `planCdn` turns a typed `Cdn` + resolved `CdnTarget` (+ Google stack
refs) into an ordered, secret-free `CdnPlan`; `renderCdnPlan` prints it for `--dry-run`;
`provisionCdn` executes it (Cloudflare via EP-57's module, Google via `gcloud` through the existing
`captureTool`, every argv pinned to `--project=tan-nb-exp`). `cdnDeployStep` calls it from the
static, server, and app deploy handlers after the origin is Ready, and a `cdn = Nothing` deploy is
a no-op. The `nagarectl cdn` command group (`list`/`status`/`purge`/`disable`) is in the parser with
the `CdnCmd`/`CdnCommand` split (avoiding the `Cdn` type clash) and `Nagare.Cdn.Status`'s pure
formatters. `cabal test`: 246 total (+9 EP-58), all green; `nagarectl cdn --help` lists the four
subcommands; the two `renderCdnPlan` goldens reproduce the exact dry-run blocks the plan specifies
(including the Google `gcloud` lines).

**Gaps / deferred.** The live legs (real Cloudflare token, real Google LB, real Cloud DNS) and the
live `cdn list`/`status` *discovery* (`queryCdnRows` currently returns `[]`) are environment-gated
and deferred, matching EP-43/EP-49. The end-to-end `site deploy --dry-run` transcript against a
loadable CDN example is captured in EP-59 (its example dirs are real loadable projects; the dry-run
*text* is already proven by the renderer goldens). One deviation from the plan's letter — CDN
orchestration in the CLI handlers rather than inside the reusable `deploy*Production` effects — is
recorded in the Decision Log with its rationale and trade-off.

