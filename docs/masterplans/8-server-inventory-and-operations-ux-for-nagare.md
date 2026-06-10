---
id: 8
slug: server-inventory-and-operations-ux-for-nagare
title: "Server Inventory and Operations UX for Nagare"
kind: master-plan
created_at: 2026-06-10T04:34:40Z
intention: "intention_01ktqwqc61e519h77zqdf3ngs3"
---

# Server Inventory and Operations UX for Nagare

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This initiative implements **Phase 9 (Server and Operations UX)** of the PaaS capability
roadmap at `docs/roadmaps/paas-gap-roadmap.md` (lines 330–348), the row the Gap Matrix
labels **"Server inventory"** (line 62: *"Mostly Pulumi/NixOS docs → `nagarectl server
status`, disk, cluster, ingress, domain, backup health"*). It is the operator-facing
counterpart to the application-facing work already delivered in
`docs/masterplans/6-application-lifecycle-and-cli-for-nagare.md` (the `app` and
`deployments` commands). Where MasterPlan 6 answered "how is my *app* doing?", this
initiative answers "how is my *server and platform* doing, and what do I do when
something is wrong?".

Today that operator story is spread across Pulumi stack outputs, NixOS host docs,
`kubectl`, Grafana, `gsutil`, and a set of runbooks (`docs/runbooks/cluster-access.md`,
`docs/runbooks/disaster-recovery.md`). An operator must remember which tool answers which
question. After this initiative, `nagarectl` itself answers those questions: a single
`nagarectl server status` prints the health of the whole platform, `nagarectl doctor`
turns each red line into an actionable remediation hint, `nagarectl domains list` shows
configured domains and their DNS/TLS readiness, and `nagarectl cleanup` reclaims disk and
prunes stale previews and releases.


## Vision & Scope

Today Nagare has no operator inventory command. To learn whether the platform is healthy,
an operator opens `docs/runbooks/disaster-recovery.md`, manually runs `gcloud compute
instances describe nagare-01`, opens an IAP-tunnelled SSH session to run `sudo k3s kubectl
get nodes` and `df -h /var/lib/nagare`, checks `kubectl rollout status` in four
namespaces, compares the Kourier `EXTERNAL-IP` against the Pulumi `publicIp` output by
eye, and runs `gsutil ls -l` to see when the last backup landed. Nothing ties these
together; nothing tells a newcomer what a bad result *means* or how to fix it.

After this initiative, an operator runs one command and reads one report. Concretely:

```text
nagarectl server status            # one-screen inventory: VM, k3s, Knative, Kourier,
                                   # cert-manager, base domain, disk usage, Artifact
                                   # Registry auth, backup freshness
nagarectl doctor                   # the same probes re-presented as pass/warn/fail
                                   # checks, each failing check carrying a concrete
                                   # remediation hint and the command to run
nagarectl domains list             # every configured domain (base domain, per-app
                                   # DomainMappings) with DNS + certificate readiness
nagarectl cleanup --dry-run        # disk reclamation: container image prune guidance,
                                   # stale preview cleanup, old release pruning
```

`nagarectl server status` prints, in one aligned table, the power state of the VM
`nagare-01`, whether the k3s node is `Ready`, whether the Knative Serving / Kourier /
cert-manager / net-certmanager control-plane deployments are rolled out, the live base
domain (read from the Pulumi `baseDomain` stack output and cross-checked against the
in-cluster `config-domain` ConfigMap), the Kourier ingress `EXTERNAL-IP` and whether it
equals the reserved `publicIp`, disk usage of the boot disk and the `/var/lib/nagare` data
disk, whether Artifact Registry push auth is configured, and the age of the most recent
object in each backup prefix of `gs://tan-nb-exp-nagare-backups/`. `nagarectl doctor`
re-runs those probes and renders them as an ordered checklist of `OK` / `WARN` / `FAIL`
lines, where every non-OK line names the problem in plain language and prints the exact
remediation command (for example, "VM is TERMINATED → run `gcloud compute instances start
nagare-01 --zone=us-west1-a`"). `nagarectl domains list` enumerates the base domain and
every Knative `DomainMapping`, showing each domain's owning Service, its DNS expectation
(wildcard `A` record → `publicIp`), and its certificate readiness. `nagarectl cleanup`
identifies reclaimable container images on the node, preview deployments whose TTL has
elapsed, and release-history entries beyond a retention count, defaulting to a dry-run
that shows what *would* be removed before anything is deleted.

What is **in scope**:

- A reusable, typed probe layer under `cli/nagarectl/src/Nagare/Ops/` that gathers
  ground-truth from the platform's existing sources (`gcloud`, `pulumi`, `kubectl`,
  `gsutil`, and IAP-tunnelled SSH via `scripts/iap-ssh.sh`) and returns typed results,
  with pure parsers and pure formatters that are unit-tested without a live cluster.
- The four operator commands above: `server status`, `doctor`, `domains list`, `cleanup`.
- A defined access model: how each probe reaches its data source, and graceful
  degradation when a source is unreachable (the VM is off, no kubeconfig, gsutil
  unavailable) so the command still prints a partial, clearly-marked report instead of
  crashing.
- Documentation that folds these commands into `docs/runbooks/cluster-access.md` and
  `docs/runbooks/disaster-recovery.md`, replacing manual procedures with command
  invocations where the command now covers them.

What is **out of scope** (deferred to later roadmap phases or follow-up plans):

- The `nagared` control-plane API and `nagarectl context` management (roadmap Phase 8).
  These commands shell out to local tooling exactly as every existing `nagarectl` command
  does; they do not introduce a remote API.
- A dashboard UI (roadmap Phase 10).
- Automatic remediation. `doctor` *prints* remediation commands; it does not execute
  destructive or state-changing fixes on the operator's behalf. `cleanup` is the one
  command that mutates, and it defaults to dry-run and requires `--confirm` to act.
- Standing up a host-level backup scheduler. No systemd backup timer exists yet (backups
  are manual scripts under `scripts/`); "backup freshness" is therefore defined purely as
  "age of the newest object in each GCS backup prefix". Building the scheduler belongs to
  a future databases/backups initiative (roadmap Phase 4).
- Continuous monitoring or alerting. These are point-in-time, operator-invoked commands,
  not daemons. Grafana/VictoriaMetrics remain the time-series story.


## Decomposition Strategy

The initiative is decomposed into **five child ExecPlans**. The guiding seam is the same
one the sibling MasterPlans use: separate the *platform plumbing and typed model* from the
*individual CLI surfaces that present it*, and keep documentation as its own closing plan.

EP-38 builds the shared probe layer and ships the first and largest consumer of it,
`nagarectl server status`. Bundling the foundations with `server status` (rather than
making the foundations a behavior-less plan) guarantees the foundation plan has a
demonstrable, user-visible outcome — you can run `nagarectl server status` and read a
report — which the MasterPlan specification requires of every work stream. EP-39 (`doctor`)
is split from EP-38 because it adds a genuinely distinct concern on top of the same
probes: a remediation knowledge base mapping each failure mode to an actionable hint, plus
a different rendering (pass/warn/fail checklist with exit-code semantics) suitable for
scripting. EP-40 (`domains list`) and EP-41 (`cleanup`) are each a self-contained command
with its own data sources (DomainMappings/Certificates for one, node image store and
release/preview history for the other) and can be built in parallel once the probe layer
exists. EP-42 closes the initiative by integrating the new commands into the existing
runbooks so the documentation and the tooling agree.

This grouping minimizes cross-plan coupling: only EP-38 defines the probe types and the
shared external-tool wrappers; every later plan consumes them additively without modifying
EP-38's functions. It maximizes independent verifiability: each command is demonstrable on
its own (`server status`, then `doctor`, then `domains list`, then `cleanup`). And it
respects natural ordering: `doctor` is meaningless without the probes it grades, so EP-38
is a hard dependency of EP-39, whereas `domains list` and `cleanup` only *benefit* from
EP-38's shared helpers and so depend on it softly.

**Alternatives considered and rejected.**

*A single ExecPlan for the whole phase.* Rejected: the roadmap itself suggests "one
ExecPlan for `doctor/status`, then follow-up plans for cleanup and domain inspection",
i.e. a multi-plan shape. One plan would exceed five milestones and touch the probe layer,
four command surfaces, and the runbooks at once — exactly the "unwieldy single ExecPlan"
the MasterPlan specification warns against.

*Merging `status` and `doctor` into one plan* (the literal roadmap suggestion). Considered
seriously, and reasonable, but rejected because the two have different shapes: `status` is
a flat inventory printer, while `doctor` adds a remediation knowledge base and
script-friendly exit codes. Keeping them separate lets `status` ship and be used while
`doctor`'s remediation content is still being written, and keeps each plan at three to
four milestones. The probe layer they share lives in EP-38 and is consumed, not modified,
by EP-39 — so the split does not create the "two plans editing the same function" smell.

*A standalone, behavior-less "foundations" plan.* Rejected: a plan that adds the
`Nagare.Ops` probe types but no command would violate the requirement that each work
stream produce a demonstrable behavior. Folding `server status` into the foundations plan
solves this while keeping the foundation as the dependency root.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-38 | Server inventory probe layer and `nagarectl server status` | docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md | None | None | Complete |
| EP-39 | `nagarectl doctor` health checks with remediation hints | docs/plans/39-nagarectl-doctor-health-checks-with-remediation-hints.md | EP-38 | None | Complete |
| EP-40 | `nagarectl domains list` with DNS and certificate readiness | docs/plans/40-nagarectl-domains-list-with-dns-and-certificate-readiness.md | None | EP-38 | Complete |
| EP-41 | `nagarectl cleanup` for images, previews, and releases | docs/plans/41-nagarectl-cleanup-for-images-previews-and-releases.md | None | EP-38 | Complete |
| EP-42 | Server and operations UX docs and runbook integration | docs/plans/42-server-and-operations-ux-docs-and-runbook-integration.md | None | EP-38, EP-39, EP-40, EP-41 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their `EP-<#>` prefix, where the number is
the child plan's file number in `docs/plans/` (matching the repository convention that
`EP-30` is `docs/plans/30-...`). The numbers continue the repository's sequential plan
numbering; the most recent existing plan before this initiative is EP-37 (a child of
MasterPlan 7).


## Dependency Graph

EP-38 is the root. It has no dependencies and defines the shared `Nagare.Ops` probe
layer — the typed check/status model, the external-tool wrappers (`gcloud`, `pulumi`,
`gsutil`, `kubectl`, `iap-ssh`), and the pure parsers/formatters — while delivering
`nagarectl server status` as its first consumer.

EP-39 (`doctor`) has a **hard dependency** on EP-38. `doctor` cannot compile or make sense
without EP-38's probe result types: it consumes the very same probe values and re-grades
them as `OK`/`WARN`/`FAIL` with remediation hints. Building `doctor` before the probes
exist would mean inventing throwaway probe code, so it waits for EP-38.

EP-40 (`domains list`) and EP-41 (`cleanup`) have **soft dependencies** on EP-38. Each
could technically be written against raw `kubectl`/`gcloud` calls, but both benefit from
EP-38's shared table formatter, base-domain resolver, and external-tool wrappers, and
should reuse them rather than duplicate them. They do not need EP-38's probe *grading*
logic. If EP-38 is complete they should consume its helpers; if work is parallelized, they
may begin against stubs of those helpers and reconcile against the real signatures (see
Integration Points). Neither blocks the other — `domains list` reads DomainMappings and
Certificates; `cleanup` reads the node image store and release/preview history — so they
can be implemented concurrently.

EP-42 (docs) softly depends on all four implementation plans: it documents whatever
commands exist. It can be drafted incrementally as each command lands and finalized once
all four are complete.

**Parallelism.** After EP-38 is complete, EP-39, EP-40, and EP-41 can all proceed in
parallel; they touch disjoint data sources and disjoint new modules, coordinating only
through the shared command registration in `cli/nagarectl/app/Main.hs` (Integration Point
IP3). EP-42 can be written alongside them and finalized last.


## Integration Points

**IP1 — The `Nagare.Ops` probe layer: typed check/status model and pure
formatters.** Defined by **EP-38** in new modules under
`cli/nagarectl/src/Nagare/Ops/` (for example `Nagare.Ops.Probe` and
`Nagare.Ops.Status`). Consumed by **EP-39** (re-grades probe results into remediation
checks), and reused by **EP-40** and **EP-41** for their table formatting. EP-38 owns the
result types. The shape EP-39 depends on is, conceptually:

```haskell
-- A single inspected platform facet and its observed state.
data ProbeStatus = StatusOk | StatusWarn | StatusUnknown | StatusFail
  deriving stock (Eq, Show)

data Probe = Probe
  { probeName    :: !Text         -- e.g. "VM", "k3s node", "Kourier ingress"
  , probeStatus  :: !ProbeStatus
  , probeDetail  :: !Text         -- e.g. "RUNNING", "EXTERNAL-IP 34.x = publicIp"
  } deriving stock (Show)

-- The full inventory gathered by `server status`.
gatherInventory :: InventoryOpts -> IO [Probe]
```

EP-39 must consume `Probe`/`ProbeStatus` as published by EP-38; if EP-39 needs an extra
field (such as a stable machine key to attach a remediation hint to), it adds that field
to EP-38's type in coordination, and EP-38's `server status` continues to render
correctly. Exact field names are finalized in EP-38 and EP-39 reads them back from the
committed module — neither plan should assume names not present in EP-38's source.

**IP2 — Base-domain resolution from Pulumi.** Today `resolveBaseDomain` in
`cli/nagarectl/app/Main.hs` (around line 1446) reads the `--base-domain` flag, then
`$NAGARE_BASE_DOMAIN`, then falls back to the literal `"apps.example.com"`; it does **not**
read Pulumi. **EP-38** adds a probe that reads the authoritative base domain via `pulumi
-C infra/pulumi stack output baseDomain` and cross-checks it against the in-cluster
`config-domain` ConfigMap in the `knative-serving` namespace. **EP-40** (`domains list`)
consumes the same resolved base domain to compute each domain's expected wildcard DNS
record. EP-38 owns the Pulumi-reading helper (for example `Nagare.Ops.Pulumi.stackOutput`);
EP-40 calls it rather than re-implementing it. The existing `resolveBaseDomain` flag/env
fallback is left in place for the deploy path and is not removed by this initiative.

**IP3 — Top-level command registration in `cli/nagarectl/app/Main.hs`.** All four
implementation plans add new top-level commands to the single `subparser` block (around
line 549) and new constructors to the `Command` sum type (around line 232), plus a
dispatch arm in `main`. EP-38 adds `server` (a command group whose first subcommand is
`status`), EP-39 adds `doctor`, EP-40 adds `domains` (group with subcommand `list`), and
EP-41 adds `cleanup`. Because all four edit the same file, the owning plan for the file's
*structure* is EP-38 (it establishes the `server` group and the pattern); later plans
append their command in the same style and must resolve textual merge conflicts in the
`subparser` block and the `Command`/`main` `case` by following EP-38's precedent. No plan
removes or renames another plan's command.

**IP4 — External-tool access model and graceful degradation.** **EP-38** establishes how
probes reach each data source and what happens when a source is unreachable: `kubectl`
runs against the operator's ambient context exactly as every existing `nagarectl` command
assumes (the operator has a working/tunnelled kubeconfig); `gcloud`, `pulumi`, and
`gsutil` run locally; the VM disk-usage probe is best-effort over `scripts/iap-ssh.sh`
(invoked with `SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519` per
`docs/runbooks/cluster-access.md`) and is reported as `Unknown` rather than failing the
whole command when SSH is not set up. EP-39, EP-40, and EP-41 inherit this model: any
probe whose source is unreachable yields a `StatusUnknown`/`WARN` line with a hint, never
an uncaught exception. EP-38 owns the wrapper functions and the degradation convention;
later plans reuse them.


## Progress

- [x] EP-38: `Nagare.Ops` probe types, external-tool wrappers, and pure parsers/formatters with unit tests.
- [x] EP-38: `gatherInventory` wiring all probes (VM, k3s, Knative, Kourier, cert-manager, base domain, disk, Artifact Registry, backup freshness).
- [x] EP-38: `nagarectl server status` command registered, rendering the inventory table; graceful degradation verified.
- [x] EP-39: Remediation knowledge base mapping each probe failure mode to a hint and command.
- [x] EP-39: `nagarectl doctor` checklist rendering with `OK`/`WARN`/`FAIL` and a non-zero exit code on failure.
- [x] EP-40: DomainMapping + Certificate inventory and DNS-expectation computation, with pure parsers tested.
- [x] EP-40: `nagarectl domains list` command registered and rendering domains with readiness.
- [x] EP-41: Reclaimable-image, stale-preview, and old-release detection with pure selectors tested.
- [x] EP-41: `nagarectl cleanup` command with `--dry-run` default and `--confirm` to act.
- [x] EP-42: Runbooks updated to invoke the new commands; end-to-end operator walkthrough documented.


## Surprises & Discoveries

- 2026-06-09 (planning, affects EP-38/39/40/41): The `Nagare.Server.*` module namespace
  is **already in use** by the full-stack server-runtime hosting feature
  (`Nagare.Server.Build`, `Nagare.Server.Deploy`, `Nagare.Server.Image`, from
  `docs/plans/18-full-stack-server-runtime-hosting-for-static-sites.md`), where "Server"
  means *a user's server-side application runtime*, not the physical host. The first draft
  of EP-38 placed the operator/inventory probe layer under `Nagare.Server.Probe` /
  `Nagare.Server.Status` / `Nagare.Server.Pulumi`, which would conflate two unrelated
  concerns in one namespace (build a user's app vs. inspect the platform). Resolved before
  any code was written by moving the entire operations layer to `Nagare.Ops.*`
  (`Nagare.Ops.Probe`, `Nagare.Ops.Pulumi`, `Nagare.Ops.Status`, and the later
  `Nagare.Ops.Doctor` / `Nagare.Ops.Domains` / `Nagare.Ops.Cleanup`). All five child plans
  and the Integration Points above reference `Nagare.Ops.*`. The CLI commands keep their
  roadmap-specified names (`nagarectl server status`, etc.); only the internal Haskell
  module namespace changed.


- 2026-06-10 (EP-38 complete, affects EP-39/40/41): The IP1/IP2/IP3/IP4 surfaces
  are now committed and stable. Concrete signatures the later plans read back:
  `Nagare.Ops.Probe` exports `ProbeStatus(StatusOk|StatusWarn|StatusUnknown|StatusFail)`,
  `Probe{probeName, probeStatus, probeDetail}`, `InventoryOpts{ioZone, ioInstance,
  ioPulumiDir, ioSkipVm}`, `renderInventory`/`statusLabel`, the `captureTool`/`runMaybe`
  wrappers, and the seven pure parsers; `Nagare.Ops.Pulumi` exports `stackOutput ::
  FilePath -> Text -> IO (Maybe Text)`; `Nagare.Ops.Status` exports
  `gatherInventory`/`defaultInventoryOpts`. The `server` command group in
  `cli/nagarectl/app/Main.hs` establishes the IP3 registration pattern (a nested
  `subparser` with a `command "<name>"` and a matching `Command` constructor +
  `main` dispatch arm). Two additions beyond the EP-38 sketch: a
  `cert-manager-cainjector` Deployment probe and an informational
  `external-domain-tls` line; neither changes the IP1 types. The `renderInventory`
  CHECK column is 25 wide (not the sketch's 22) so the longest probe name fits —
  EP-40/EP-41 should reuse `renderInventory`/`statusLabel` rather than re-deriving
  widths.


## Decision Log

- Decision: Implement roadmap Phase 9 ("Server and Operations UX", the Gap Matrix's "Server
  inventory" row) as a MasterPlan with five child ExecPlans (EP-38 probe layer + `server
  status`, EP-39 `doctor`, EP-40 `domains list`, EP-41 `cleanup`, EP-42 docs) rather than a
  single ExecPlan.
  Rationale: the roadmap explicitly suggests a multi-plan shape ("one ExecPlan for
  `doctor/status`, then follow-up plans for cleanup and domain inspection"); a single plan
  would exceed five milestones and touch the probe layer, four command surfaces, and two
  runbooks at once, which the MasterPlan specification flags as an unwieldy single plan.
  Date: 2026-06-09

- Decision: Bundle the shared probe layer with `nagarectl server status` in EP-38 rather
  than making a standalone behavior-less "foundations" plan.
  Rationale: every work stream must produce a demonstrable behavior; folding `server
  status` into the foundation gives EP-38 a runnable, user-visible outcome while still
  serving as the dependency root that EP-39 hard-depends on and EP-40/EP-41 soft-depend on.
  Date: 2026-06-09

- Decision: Split `doctor` (EP-39) from `status` (EP-38) even though the roadmap suggests
  one plan for both.
  Rationale: `doctor` adds a distinct concern — a remediation knowledge base and
  script-friendly pass/warn/fail exit-code semantics — on top of the same probes. The
  split keeps each plan at three to four milestones and lets `status` ship independently.
  `doctor` consumes EP-38's probe types without modifying them, so the split does not
  create a shared-function-edit conflict.
  Date: 2026-06-09

- Decision: Make EP-40 (`domains list`) and EP-41 (`cleanup`) soft, not hard, dependents of
  EP-38.
  Rationale: each command has independent data sources and could be written without EP-38,
  but both should reuse EP-38's table formatter, base-domain resolver, and tool wrappers.
  A soft dependency captures "reuse if available, do not block on it" and allows EP-39/40/41
  to be parallelized after EP-38.
  Date: 2026-06-09

- Decision: Define "backup freshness" as the age of the newest object in each
  `gs://tan-nb-exp-nagare-backups/` prefix, and exclude building a backup scheduler from
  this initiative.
  Rationale: no host-level backup timer exists yet (backups are manual scripts under
  `scripts/`); a scheduler belongs to the future databases/backups initiative (roadmap
  Phase 4). Reporting newest-object age is achievable today with `gsutil` and gives the
  operator a real freshness signal.
  Date: 2026-06-09

- Decision: `doctor` prints remediation commands but never executes state-changing fixes;
  `cleanup` is the only mutating command and defaults to `--dry-run`, requiring `--confirm`
  to act.
  Rationale: operator-safety. Auto-remediation on a single-node personal PaaS risks
  destructive surprises; making the operator copy-paste the printed command keeps a human
  in the loop.
  Date: 2026-06-09

- Decision: Place the new operator/inventory Haskell modules under the `Nagare.Ops.*`
  namespace rather than `Nagare.Server.*`.
  Rationale: `Nagare.Server.*` is already occupied by the full-stack server-runtime hosting
  feature (`Nagare.Server.Build/Deploy/Image`), where "Server" denotes a user's server-side
  app, not the physical host. Reusing it for platform inspection would conflate unrelated
  concerns. The CLI command names from the roadmap (`server status`, `doctor`, `domains`,
  `cleanup`) are unaffected; only the internal module namespace differs.
  Date: 2026-06-09

- Decision: Number the initiative MasterPlan as 8 and its children as EP-38 through EP-42.
  Rationale: 7 is the highest existing MasterPlan and 37 the highest existing ExecPlan;
  these continue the repository's single global sequential numbering for both.
  Date: 2026-06-09


## Outcomes & Retrospective

All five child ExecPlans are complete (EP-38 → EP-42); the initiative is delivered.
Roadmap Phase 9 / the Gap Matrix "Server inventory" row is closed: an operator now answers
"is my platform healthy, what is wrong and how do I fix it, what are my domains, and how do
I reclaim disk?" entirely from `nagarectl`, instead of stitching together Pulumi outputs,
NixOS docs, `kubectl`, Grafana, `gsutil`, and runbook steps.

What shipped:

- **EP-38** — the reusable `Nagare.Ops.*` probe layer (`Nagare.Ops.Probe` typed model +
  IP4 `captureTool`/`runMaybe` wrappers + seven pure parsers; `Nagare.Ops.Pulumi.stackOutput`;
  `Nagare.Ops.Status.gatherInventory`) and `nagarectl server status` — an 18-line
  `STATUS/CHECK/DETAIL` inventory that degrades every unreachable source to `UNKNOWN`.
- **EP-39** — `nagarectl doctor`: `Nagare.Ops.Doctor` re-grades the same probes into an
  `OK/WARN/FAIL` checklist with a repo-accurate fix command on each non-OK line, and exits 1
  on any `FAIL` (scriptable).
- **EP-40** — `nagarectl domains list`: `Nagare.Ops.Domains` with the DomainMapping/Certificate
  extractors, computed wildcard DNS expectation, cert grader, and table; graceful TLS-disabled
  and no-cluster handling.
- **EP-41** — `nagarectl cleanup`: `Nagare.Ops.Cleanup` with the pure release-trim/preview-staleness/
  image-parse selectors and `executeCleanup`; the only mutating command, dry-run by default,
  `--confirm` to act.
- **EP-42** — `docs/runbooks/server-operations.md` (the day-2 guide + "TERMINATED → green"
  recovery scenario) and the `cluster-access.md` / `disaster-recovery.md` integrations.

Integration points held as designed: IP1 (the `Probe`/`ProbeStatus` types) was consumed
verbatim by EP-39/40/41 with no breaking change; IP3 (the shared `subparser` block in
`cli/nagarectl/app/Main.hs`) accreted four new top-level commands (`server`, `doctor`,
`domains`, `cleanup`) with no removals; IP4 (the `captureTool` degradation convention) was
reused by EP-40 and EP-41 for missing-binary tolerance.

Cross-plan lessons (see each plan's Surprises): (1) `cli/nagarectl/app/Main.hs` has no
`cradle` dependency, so all subprocess IO for the new commands lives in library modules and
`Main.hs` stays thin — EP-40 and EP-41 both followed this. (2) EP-38 shipped display-name
probe keys and no separate machine key, so EP-39 keyed its knowledge base off `probeName`
with a generic fallback (no bare red lines). (3) The CHECK column width was widened to 25 so
`cert-manager-cainjector` fits. (4) `doctor` has no probe for the post-reboot host workarounds,
so EP-42's recovery scenario documents it flagging the downstream symptoms and cross-links
the root-cause fixes rather than overclaiming.

Verification posture: 171 unit tests pass (pure parsers, selectors, graders, and formatters
across all four `Nagare.Ops.*` modules). The mutating/live paths were proven deterministically
without touching real infrastructure — `doctor`'s FAIL/exit-1 via a `gcloud` stub, graceful
degradation via an empty PATH, `cleanup`'s dry-run-by-default — and every `--help`/transcript
in the docs was captured from the built binary. Per the GCP project-isolation rule and because
`nagare-01` is commonly `TERMINATED`, the live healthy-cluster runs are deferred (recorded in
each child plan); the pure contracts and the degraded transcripts are the evidence.
