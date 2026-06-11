---
id: 13
slug: live-audit-hardening-control-plane-abstractions-and-declarative-cluster-configuration
title: "Live-Audit Hardening: Control-Plane Abstractions and Declarative Cluster Configuration"
kind: master-plan
created_at: 2026-06-11T02:35:43Z
intention: "intention_01ktt8he4vepkb0gbp2k9z5fc3"
---

# Live-Audit Hardening: Control-Plane Abstractions and Declarative Cluster Configuration

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

On 2026-06-10 the `nagare-01` cluster was found still running, and the live tests that nine
master plans had deferred behind a powered-off VM were finally executed. They passed — but only
after exposing a cluster of latent defects and design smells that had survived precisely because
the live paths had never run. This initiative fixes those root causes, and it fixes them at the
right altitude: it corrects the **abstractions**, rather than papering over symptoms.

The defects shared two structural causes. First, **control-plane logic had leaked into shell
scripts.** Backup, restore, and snapshot were split between typed `nagarectl` renderers and
hand-maintained bash that rendered Kubernetes Jobs in heredocs and re-implemented Google Cloud
Storage (GCS) authentication. The authentication helper (mapping `metadata.google.internal` to the
metadata IP via a pod `hostAliases` entry, so a pod can mint the node service account's access
token) was present in the database-backup renderer but missing from the volume-snapshot renderer
and from `scripts/restore-volume.sh`; both failed live with `401 Anonymous`. Volume *restore* did
not exist in the control plane at all — it lived only as a script. Second, **cluster capabilities
were configured imperatively, by hand, on the live box, instead of declaratively in the NixOS host
image and the cluster bootstrap.** The cluster could not pull private images from the project's own
Artifact Registry (no `/etc/rancher/k3s/registries.yaml`; no `registriesSkippingTagResolving` in
Knative's `config-deployment`), and the only reason a build-mode deploy ever worked was a manual,
expiring-token fix applied during the audit.

After this initiative:

- **One typed abstraction renders every GCS-backed data-movement Job.** A new low-level module
  emits the canonical pod scaffolding — the `google/cloud-sdk` image, the `metadata.google.internal`
  `hostAliases`, the `GCE_METADATA_HOST`/`CLOUDSDK_CORE_PROJECT` environment, the
  `restartPolicy`/`backoffLimit` — exactly once. Database backup, database restore, volume snapshot,
  and a new volume restore all render through it, so the GCS-auth bug cannot recur in one path while
  another is fixed. The hand-rolled bash scripts (`restore-volume.sh`, `backup-postgres.sh`,
  `restore-postgres.sh`, `restore-sqlite.sh`) are **deleted**; the disaster-recovery runbook invokes
  `nagarectl` verbs directly. A new `nagarectl storage restore APP VOLUME BACKUP_ID [--into-live]`
  verb gives volume restore the same scratch-first treatment database restore already has.

- **The cluster pulls its own private images out of the box.** `registries.yaml` is declared in the
  NixOS host configuration with a durable credential mechanism (not a one-hour manual token), and
  `registriesSkippingTagResolving` is part of the Knative bootstrap. A fresh `nagarectl deploy` of a
  build-mode app to a freshly provisioned cluster succeeds with no manual intervention.

- **`nagarectl` builds images for the cluster's architecture.** The node is `amd64`; a developer's
  build daemon is frequently `arm64`. The target architecture is part of the target profile and
  `nagarectl` passes it to `docker build`/`nixpacks`, instead of relying on the operator remembering
  to export `DOCKER_DEFAULT_PLATFORM`.

- **The control plane tells the truth.** `nagarectl doctor` no longer false-FAILs the Kourier
  ingress check on a k3s node-IP LoadBalancer that the reserved static IP fronts; it gains checks
  for private-image pullability and build/node architecture mismatch. The 2-vCPU node has
  observability resource *requests* sized so that an application plus a database can actually
  co-schedule.

- **Regressions of this class are caught automatically.** A CI pipeline (nix flake checks plus a
  thin GitHub Actions workflow) compiles every example `Config.hs`, runs the Haskell test suites,
  and a periodic/manual **live** smoke test deploys a private-image app, snapshots and restores a
  volume, and tears down — exercising the exact paths that were dark for weeks.

- **The developer and operator ergonomics that made the audit painful are gone.** `nagarectl`
  resolves the loader's GHC package environment itself (no hand-captured `--ghc-env` file);
  `scripts/iap-ssh.sh` reads its SSH user from the target profile (defaulting to `deploy`) instead
  of the OS-Login name that always fails here; and `just live-test` stands up the workstation→cluster
  harness (the IAP port-22 tunnel, the rewritten kubeconfig) in one command.

**In scope:** the seven remediation areas above, decomposed into six child ExecPlans. **Out of
scope (separately gated, unchanged by this initiative):** wildcard TLS/HTTPS and the CDN edge proofs,
which require a real delegated domain, a Cloudflare API token, and a deliberate billable `pulumi up`
— external dependencies that the running VM did not and this initiative does not supply. Those
remain recorded as deferred in MasterPlans 1 and 11.


## Decomposition Strategy

The initiative is decomposed by **functional concern and altitude**, not by file. Two concerns are
"correct the abstraction" work in the typed control plane and one is "make the cluster declarative";
these form Phase 1, because the later verification and diagnostics work is only meaningful once the
real behaviors exist. Phase 2 is verification, truthful diagnostics, and ergonomics.

The guiding principles were: (1) **one writer per shared artifact** — the shared GCS-Job module, the
target-profile schema, and the `doctor` check set each have exactly one owning plan, so two plans
cannot make incompatible assumptions; (2) **independent verifiability** — each plan ends in a
behavior demonstrable on its own (a verb that runs, a fresh cluster that pulls a private image, a
`doctor` run that no longer lies); (3) **minimize hard dependencies** — the three Phase-1 plans have
no hard dependencies on each other and can proceed in parallel, and the Phase-2 plans take only soft
or integration dependencies so they are never fully blocked.

Phase 1 — correct the abstractions and make the cluster declarative:

- **EP-1 Unified GCS data-movement Job abstraction & restore unification.** The core "abstraction"
  plan. Introduces the shared low-level Job module, refactors database backup/restore and volume
  snapshot onto it (permanently fixing the `hostAliases`/401 bug in one place and breaking the
  existing `Nagare.Database.Backup`↔`Nagare.Storage.Snapshot` import cycle), adds the new
  `storage restore` verb, and **deletes** the four hand-rolled bash scripts, updating the
  disaster-recovery runbook to call `nagarectl` verbs.

- **EP-2 Declarative private-image pull & cluster capacity hardening.** Makes the two cluster
  capabilities the audit configured by hand into infrastructure-as-code: `registries.yaml` (with a
  durable credential mechanism) in the NixOS host, `config-deployment` with
  `registriesSkippingTagResolving` in the Knative bootstrap, and right-sized observability resource
  requests for the 2-vCPU node.

- **EP-3 Cross-architecture build in the target profile & `nagarectl`.** Adds a target-architecture
  field to the target profile and `Nagare.Target`, and makes `Nagare.Build` pass `--platform` to
  `docker build`/`nixpacks`, so build-mode deploys produce node-runnable images without an env var.

Phase 2 — verify, diagnose truthfully, and smooth the edges:

- **EP-4 `doctor` diagnostics correctness.** Fixes the Kourier-ingress false-FAIL and adds the
  private-image-pull and build/node-arch checks whose semantics EP-2 and EP-3 establish.

- **EP-5 CI pipeline & live smoke test.** Establishes the CI that does not exist today (nix flake
  checks as the source of truth, a thin GitHub Actions workflow invoking them), including the
  compile-every-example-`Config.hs` guard, and a periodic/manual live smoke test exercising the
  Phase-1 behaviors end-to-end.

- **EP-6 CLI & operator-harness ergonomics.** `nagarectl` resolves the loader GHC environment
  itself; `iap-ssh.sh` reads the SSH user from the target profile; `just live-test` provides the
  one-command workstation harness.

Alternatives considered and rejected. *Folding the doctor fixes into EP-2/EP-3:* rejected because
`Nagare.Ops.Doctor`/`Probe` is a single cohesive surface with one writer; splitting its edits across
three plans invites conflicting changes to the same check table. *Keeping thin break-glass wrappers
for the scripts (instead of deleting them):* rejected per the user's decision (2026-06-11) — the
control-plane logic must live solely in the app, and the DR runbook will call `nagarectl` verbs
directly. *A single mega-plan:* rejected — the work touches the DSL/CLI, the NixOS host, the cluster
bootstrap, and CI across far more than ten files in unrelated modules, which is exactly the
MasterPlan threshold.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Unified GCS Data-Movement Job Abstraction and Restore Unification | docs/plans/65-unified-gcs-data-movement-job-abstraction-and-restore-unification.md | None | None | Complete |
| EP-2 | Declarative Private-Image Pull and Cluster Capacity Hardening | docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md | None | None | Complete |
| EP-3 | Cross-Architecture Build in the Target Profile and nagarectl | docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md | None | None | Complete |
| EP-4 | Doctor Diagnostics Correctness | docs/plans/68-doctor-diagnostics-correctness.md | None | EP-2, EP-3 | Not Started |
| EP-5 | CI Pipeline and Live Smoke Test | docs/plans/69-ci-pipeline-and-live-smoke-test.md | None | EP-1, EP-2, EP-3 | Not Started |
| EP-6 | CLI and Operator-Harness Ergonomics | docs/plans/70-cli-and-operator-harness-ergonomics.md | None | EP-3 | Not Started |

Phases: **Phase 1** = EP-1, EP-2, EP-3 (parallelizable). **Phase 2** = EP-4, EP-5, EP-6.
EP-3↔EP-6 share an integration point (the target-profile schema); EP-4↔EP-2/EP-3 and EP-5↔EP-1/EP-2/EP-3 are soft. See Dependency Graph and Integration Points.


## Dependency Graph

The three Phase-1 plans — EP-1 (GCS-Job abstraction), EP-2 (declarative cluster config), EP-3
(cross-arch build) — have **no hard dependencies** and may be implemented fully in parallel. They
touch disjoint primary surfaces: EP-1 lives in `cli/nagarectl/src/Nagare/{Database,Storage}` and the
scripts/runbook; EP-2 in `nixos/hosts/nagare-01/` and `cluster/bootstrap/`; EP-3 in
`cli/nagarectl/src/Nagare/{Target,Build}.hs` and the profile schema.

The Phase-2 plans take only **soft** or **integration** dependencies, so none is ever hard-blocked:

- **EP-4 (`doctor`)** has a soft dependency on **EP-2** and **EP-3**: the Kourier-ingress fix is
  fully independent and can land first, but the two *new* checks (private-image pullability;
  build/node architecture mismatch) describe behaviors that EP-2 and EP-3 establish, so they are most
  meaningful once those land. EP-4 can implement the Kourier fix immediately and add the new checks
  as EP-2/EP-3 complete.

- **EP-5 (CI & smoke)** has a soft dependency on **EP-1, EP-2, EP-3**: the offline CI (flake checks,
  example-config compile, cabal tests) is independent and valuable immediately; the *live* smoke test
  is only meaningful once private-image pull (EP-2), cross-arch build (EP-3), and the unified
  restore verb (EP-1) exist, since the smoke scenario deploys a private build-mode app and
  snapshots/restores a volume.

- **EP-6 (ergonomics)** has an **integration** dependency on **EP-3**: both extend the target-profile
  schema and `Nagare.Target` (EP-3 adds the architecture field; EP-6 adds the SSH-user field). They
  do not block each other, but they must agree on the record shape, the `nagare.target.env` schema,
  and the precedence rule. See Integration Points.

Recommended order when implementing serially: EP-1, EP-3, EP-2 (Phase 1), then EP-6, EP-4, EP-5
(Phase 2) — so the profile-schema integration (EP-3↔EP-6) is settled before EP-4's arch check and
EP-5's smoke depend on it. Parallel implementation is fully supported with the Integration Points
honored.


## Integration Points

1. **The shared GCS data-movement Job module (new).** Owned and defined by **EP-1** (proposed
   `cli/nagarectl/src/Nagare/Cluster/GcsJob.hs`, name to be finalized in EP-1). It exports the
   canonical pod-spec scaffolding for a Job that moves data to/from GCS using the node service
   account's Application Default Credentials: the `google/cloud-sdk:slim` container, the
   `metadata.google.internal` → `169.254.169.254` `hostAliases`, the
   `GCE_METADATA_HOST`/`CLOUDSDK_CORE_PROJECT` env, and the `restartPolicy: Never`/`backoffLimit: 0`
   shape. `Nagare.Database.Backup`, `Nagare.Database.Restore`, `Nagare.Storage.Snapshot`, and the new
   `Nagare.Storage.Restore` all consume it. Placing it *below* both `Database` and `Storage` in the
   module graph is what breaks the current `Backup`↔`Snapshot` import cycle. **EP-5** consumes it
   only indirectly (its live smoke exercises the rendered Jobs). No other plan edits it.

2. **The target-profile schema: `Nagare.Target.TargetProfile`, `nagare.target.env(.example)`, and
   `scripts/lib/target.sh`.** This record and the environment-file schema are extended by **two**
   plans and must agree. **EP-3** is the *first writer*: it adds the target **architecture** field
   `NAGARE_TARGET_PLATFORM` (Haskell field `tpTargetPlatform`, default `linux/amd64`) to the
   `TargetProfile` record, `nagare.target.env.example`, and the shell mirror `scripts/lib/target.sh`.
   **EP-6** then adds the **SSH user** field `NAGARE_SSH_USER` (default `deploy`) — but, per EP-6's
   design decision, **shell-side only** (`nagare.target.env.example` + `scripts/lib/target.sh`),
   *not* the Haskell `TargetProfile` record, because no Haskell code reads it (only `iap-ssh.sh` does);
   adding it to the record would be dead code. Both fields follow the precedence rule from `CLAUDE.md`
   and EP-60: environment variable > profile file > built-in default. EP-3 owns the example-file
   ordering and establishes the append-only convention; EP-6 appends its env line below EP-3's. The
   two plans must not both insert at the same anchor in `nagare.target.env.example`/`target.sh` — EP-6
   appends after EP-3's line regardless of merge order.

3. **The `doctor` check set: `Nagare.Ops.Doctor` and `Nagare.Ops.Probe`.** **EP-4** is the *single
   writer*. The Kourier-ingress check (currently asserting the LoadBalancer `EXTERNAL-IP` equals the
   Pulumi `publicIp`) is corrected by EP-4. EP-4 also adds two new checks whose *semantics* come from
   sibling plans: a private-image-pull readiness check (the cluster capability EP-2 makes declarative)
   and a build/node architecture-mismatch check (the field EP-3 adds to the profile). EP-2 and EP-3
   do **not** edit `Doctor.hs`/`Probe.hs`; they provide the underlying capability/field and EP-4
   implements the probe. This keeps one writer on the check table.

4. **The Knative/k3s cluster configuration: `cluster/bootstrap/knative-serving/` and
   `nixos/hosts/nagare-01/k3s.nix`.** Owned by **EP-2** (adds `config-deployment.yaml` with
   `registriesSkippingTagResolving` and the `registries.yaml` host declaration). **EP-5**'s live smoke
   test depends on these being applied to the cluster under test but does not edit them.


## Progress

Track milestone-level progress across all child plans. Each child plan owns the detail; this is the
at-a-glance roll-up.

- [x] EP-1: Shared `Nagare.Cluster.GcsJob` module rendering the canonical GCS data-movement pod scaffolding
- [x] EP-1: `Database.Backup`/`Database.Restore`/`Storage.Snapshot` refactored onto it; `Backup`↔`Snapshot` cycle broken
- [x] EP-1: New `nagarectl storage restore APP VOLUME BACKUP_ID [--into-live]` verb (scratch-first)
- [x] EP-1: Bash scripts deleted; disaster-recovery runbook calls `nagarectl` verbs
- [x] EP-2: `registries.yaml` (durable credential mechanism) declared in `nixos/hosts/nagare-01/`
- [x] EP-2: `config-deployment.yaml` (`registriesSkippingTagResolving`) in the Knative bootstrap
- [x] EP-2: Observability resource requests right-sized for the 2-vCPU node (app + DB co-schedule)
- [x] EP-3: Target-architecture field in `Nagare.Target` + `nagare.target.env(.example)` schema
- [x] EP-3: `Nagare.Build` passes `--platform` to `docker build`/`nixpacks`
- [ ] EP-4: Kourier-ingress check accepts a node-IP LoadBalancer fronted by the static IP
- [ ] EP-4: New `doctor` checks: private-image pullability; build/node architecture mismatch
- [ ] EP-5: Nix flake checks + GitHub Actions workflow; compile-every-example-`Config.hs` guard
- [ ] EP-5: Periodic/manual live smoke test (private-image deploy + volume snapshot/restore + teardown)
- [ ] EP-6: `nagarectl` resolves the loader GHC environment itself (no hand-captured `--ghc-env`)
- [ ] EP-6: `iap-ssh.sh` reads SSH user from the target profile (default `deploy`); `just live-test` harness


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- The root findings this initiative addresses were captured live on 2026-06-10 and recorded in the
  affected master plans: the GCS-auth `hostAliases` bug (`docs/masterplans/7-persistent-storage-for-nagare.md`,
  `docs/masterplans/9-managed-databases-for-nagare.md`), the private-image-pull gap
  (`docs/masterplans/4-application-build-modes-for-nagare.md` Outcomes), and the `doctor`
  Kourier-ingress false-FAIL (`docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md`).

- **EP-1 complete (2026-06-11): Integration Point #1 is now concrete.** The shared module landed as
  `cli/nagarectl/src/Nagare/Cluster/GcsJob.hs` (name as proposed) exporting `metadataHostAliases ::
  Value`, `metadataEnv :: Text -> [Value]`, `gcsContainerImage :: Text`, `DataMovementJob (..)`, and
  `dataMovementJobSpec :: DataMovementJob -> Value`. It owns the *whole* `.spec` body (not just the
  `hostAliases` fragment), so adoption is all-or-nothing — the recurrence guard
  (`gcsJobHostAliasesTests`) covers all four renderers and was proven to fail every case at once when
  the shared line is removed. EP-5's live smoke exercises these rendered Jobs but must not edit the
  module. The `Backup`↔`Snapshot` cycle is broken; `cabal build` is cycle-free and the suite is 262
  green. EP-1 added two `Nagare.Storage.*` consumers but left the target-profile schema (IP #2) and
  the `doctor` check set (IP #3) untouched, so EP-3/EP-6 and EP-4 are unaffected.

- **EP-3 complete (2026-06-11): Integration Point #2 first-writer landed; the append anchor for
  EP-6 is concrete.** `tpTargetPlatform :: !Text` (env `NAGARE_TARGET_PLATFORM`, default
  `linux/amd64`) is the **last** field of `Nagare.Target.TargetProfile`; the matching
  `export NAGARE_TARGET_PLATFORM=linux/amd64` is the **last** line of `nagare.target.env.example`
  and of `Nagare.Init.renderTargetEnv`; and `TARGET_PLATFORM="${NAGARE_TARGET_PLATFORM:-linux/amd64}"`
  is the last derivation in `scripts/lib/target.sh`. **EP-6 must append `NAGARE_SSH_USER` (shell-side
  only, per the Decision Log) after each of these.** EP-3 deliberately did *not* touch
  `Doctor.hs`/`Probe.hs`; EP-4 will *read* `tpTargetPlatform` for its build/node arch-mismatch check.
  Note for EP-5's smoke: `nagarectl deploy` takes the config via `-f`/`--file`, not a positional app
  name. 264 tests green.

- **EP-2 complete (2026-06-11): the cluster pulls its own private images and fits a real workload,
  declaratively — verified live.** M1 spike chose the systemd-timer credential mechanism
  (`auth-provider-gcp` absent from nixpkgs); `registries.nix` applied via `host-switch`; the Knative
  `config-deployment` carries the AR host in `registriesSkippingTagResolving`; observability CPU
  requests trimmed so an app+DB co-schedule. Headline proven: a private-image ksvc reached `Ready`
  pulling the private image with no manual token/patch. **Cross-plan impacts:** (1) a **pre-existing,
  EP-2-orthogonal** sops gap (`/var/lib/sops-nix/age-key.txt` absent → secrets never materialize →
  Tailscale logged out → `host-switch` runs over an IAP tunnel and `switch-to-configuration` exits
  non-zero on the `tailscaled-autoconnect` timeout) — a useful follow-up but not in MP13 scope; (2)
  the **EP-6 GHC-env foot-gun is confirmed real and load-bearing for live ops** — the raw `nagarectl`
  binary can't load `Config.hs` outside `cabal run` (no `GHC_ENVIRONMENT`), so EP-6 is effectively a
  prerequisite for EP-5's one-command live smoke; (3) `just host-image` (fresh-image parity bake) was
  intentionally not run — the `host-switch` closure build satisfies the plan's "build success is
  sufficient" bar, and the actual bake is a billable infra mutation scoped out for routine validation.
  Integration Point #4 (`cluster/bootstrap/knative-serving/`, `nixos/hosts/nagare-01/`) is owned
  solely by EP-2; EP-5 will exercise these but not edit them.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision (2026-06-11): Decompose into six child ExecPlans across two phases (3 abstraction/infra in
  Phase 1; 3 verification/diagnostics/ergonomics in Phase 2), with one writer per shared artifact.
  Rationale: the seven remediation areas split cleanly by functional concern and altitude; the
  Phase-1 behaviors must exist before the Phase-2 verification/diagnostics are meaningful, but no hard
  dependencies are needed within or across phases — only soft/integration — so work parallelizes.

- Decision (2026-06-11): **Delete** the hand-rolled bash scripts (`restore-volume.sh`,
  `backup-postgres.sh`, `restore-postgres.sh`, `restore-sqlite.sh`) rather than reduce them to thin
  break-glass wrappers; the disaster-recovery runbook will call `nagarectl` verbs directly. Rationale:
  user decision — control-plane logic must live solely in the typed app, not be hidden in or
  duplicated by scripts. Trade-off accepted: disaster recovery now requires the `nagarectl` binary on
  the operator box (recorded as an explicit DR prerequisite in EP-1's runbook update).

- Decision (2026-06-11): CI runs as **nix flake checks (source of truth) invoked by a thin GitHub
  Actions workflow**. Rationale: user decision — local/hosted parity, and the checks remain runnable
  from any environment without depending solely on a hosted runner.

- Decision (2026-06-11): `NAGARE_SSH_USER` (EP-6) is added **shell-side only** (the
  `nagare.target.env.example` schema and `scripts/lib/target.sh`), not the Haskell `TargetProfile`
  record. Rationale: only `scripts/iap-ssh.sh` reads it; putting it in the Haskell record would be
  unread dead code. The architecture field `NAGARE_TARGET_PLATFORM` (EP-3) *is* in the Haskell record
  because `Nagare.Build` consumes it. Both follow env > profile > default and append-only ordering in
  the env example. (Recorded here so the EP-3↔EP-6 schema integration is unambiguous regardless of
  merge order.)

- Decision (2026-06-11): The shared GCS-Job module sits *below* both `Nagare.Database.*` and
  `Nagare.Storage.*` in the module graph (EP-1). Rationale: it is the only way to share the helper
  without the `Backup`↔`Snapshot` import cycle that already exists (discovered during the live audit
  when importing `metadataHostAliases` from `Database.Backup` into `Storage.Snapshot` failed to
  compile).


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
