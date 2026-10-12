---
id: 35
slug: deploy-time-pvc-provisioning-and-nagarectl-storage-list-and-inspect-commands
title: "Deploy-time PVC provisioning and nagarectl storage list and inspect commands"
kind: exec-plan
created_at: 2026-06-10T00:44:35Z
intention: "intention_01ktqfjpdqewga3t0rm9crehxx"
master_plan: "docs/masterplans/7-persistent-storage-for-nagare.md"
---

# Deploy-time PVC provisioning and nagarectl storage list and inspect commands

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [35-deploy-time-pvc-provisioning-and-nagarectl-storage-list-and-inspect-commands.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/35-deploy-time-pvc-provisioning-and-nagarectl-storage-list-and-inspect-commands.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Today a Nagare app is stateless. A developer writes a typed configuration file
(`nagare/Config.hs`) that evaluates to a `Deployment` value, runs `nagarectl deploy`, and the
command-line tool builds a container image, pushes it, applies a Knative Service to the cluster, and
waits for it to become Ready. A **Knative Service** is the Kubernetes object that runs an app's
container and gives it a URL; when its pod restarts or scales to zero, anything the container wrote to
its local filesystem is lost.

A sibling plan, **EP-34** (`docs/plans/34-typed-volume-and-mount-model-with-pvc-and-volumemount-renderer.md`),
adds a typed list of durable **volumes** to that `Deployment` value and teaches the renderer to emit,
for each volume, a **PersistentVolumeClaim** (the Kubernetes object an app uses to request a durable
disk — "PVC" for short) plus the matching `volumes`/`volumeMounts` stanzas inside the Knative Service
so the container sees its disk at a chosen path such as `/data`. EP-34 is pure DSL-and-renderer work:
it produces the YAML but never talks to a cluster.

This plan, **EP-35**, is the first plan that makes the volumes *real on the cluster*. After this
change a developer who declares one or more volumes in `nagare/Config.hs` can:

- Run `nagarectl deploy` and watch it **create the durable disks before it creates the app**. The
  command renders the PVC manifests, `kubectl apply`s them first, then applies the Knative Service,
  then waits for the app to become Ready. The PVCs persist across re-deploys: a second
  `nagarectl deploy` does not recreate or wipe the disk.
- Run `nagarectl deploy --dry-run` and **see the PVC manifests printed before the Service manifest**,
  with no cluster side effects, so they can review exactly what will be created.
- Run `nagarectl storage list myapp` to see a table of the app's volumes — volume name, PVC name,
  requested size, bound status, and the host path the disk lives at.
- Run `nagarectl storage inspect myapp data` to see the full detail of one volume's PVC (the raw
  `kubectl describe` / YAML view).

The observable win: a developer can attach a durable disk to an ordinary Nagare app with a typed
declaration and one deploy, and then inspect it from the CLI — something impossible today, where the
only persistence example in the repo (`cluster/examples/sqlite-litestream/`) is hand-written raw
Kubernetes YAML, not a Nagare app.

Apps with **no** declared volumes — the overwhelmingly common case today — must behave *exactly* as
they do now: no PVC step, no extra output, identical deploy. This plan preserves that completely.

## Progress

- [x] M1.1: Confirm EP-34's renderer/discovery interface is available. (2026-06-09; EP-34 merged
      `renderVolumeClaims`, `pvcName`, and the `nagare.dev/app|volume|managed-by` labels — consumed
      directly, not stubbed.)
- [x] M1.2: Add `applyPVCs` and `pvcPhases` to `cli/nagarectl/src/Nagare/Deploy.hs` using
      `cradle`/`kubectl`, with the apply-then-(Ready)-then-report ordering. (2026-06-09; named
      `pvcPhases` not `confirmPVCsBound` — it reports phase, never gates, per the Decision Log.)
- [x] M1.3: Modify `runDeploy` in `cli/nagarectl/app/Main.hs` to render the PVC manifests, print them
      before the Service in `--dry-run`, and apply them before the Service in a live deploy; preserve
      the zero-volume path. (2026-06-09; `reportPVCs` prints a per-volume bound line after Ready.)
- [x] M1.4: `cabal build` clean; `nagarectl deploy --dry-run` shows PVCs before the Service for a
      volume-bearing config and is unchanged for a no-volume config. (2026-06-09; verified through the
      real binary — volume config emits the PVC block first with min=max=1/rollout-duration=0s; the
      no-volume config emits 0 PVC blocks and keeps its original min=0/max=3 annotations.)
- [x] M2.1: Create `cli/nagarectl/src/Nagare/Storage/Discover.hs` and register it in `nagarectl.cabal`.
      (2026-06-09; `appPVCLabelSelector`, `PVCRow`, `extractPVCStatus`, `listAppPVCs`, `readPVNodePath`,
      `formatStorageTable`, re-exported `pvcName`.)
- [x] M2.2: Create `Nagare/Storage/List.hs` (`storage list`) and `Nagare/Storage/Inspect.hs`
      (`storage inspect`). (2026-06-09; both take the resolved `Deployment` — see Decision Log.)
- [x] M2.3: Wire a `storage` subparser into `cli/nagarectl/app/Main.hs` with `list` and `inspect`,
      designed so EP-36 can add `snapshot` without restructuring. (2026-06-09; `Storage StorageCommand`
      reusing `StoreCommonOpts` + `resolveStorageDep`.)
- [x] M2.4: Add pure tests to `cli/nagarectl/test/Spec.hs` for the table formatter, the PVC-status
      JSON extraction, and the label-selector/PVC-name construction. (2026-06-09; new
      `Nagare.Storage.Discover` group — all 112 tests pass.)
- [x] M2.5: `cabal test` green; `nagarectl storage list APP` runs end to end. (2026-06-09; CLI verified
      end-to-end through the real binary — config load → declared-volume join → cluster query → table.
      The live-cluster API path is exercised by the unit-tested parser; a *workstation* `kubectl`
      cannot reach the k3s API directly because IAP only forwards SSH (port 22), so the real-PVC-data
      transcript is deferred to EP-37's on-cluster end-to-end examples. See Surprises.)

## Surprises & Discoveries

- **The tree was further along than the plan assumed.** `Nagare.App` (EP-30) *does* exist now (with
  `appIdentityOrDie`, `lookupPath`/`textAt`-style defensive JSON helpers, and `pad` table
  formatting). The plan's line numbers had drifted (the `Command` sum type, `commandParser`, and
  `runDeploy` all moved). I mirrored the *current* `app`/`env` subparser shape: the `storage`
  commands reuse `StoreCommonOpts` (positional `APP` + `-f` config + `--ghc-env`) and a
  `resolveStorageDep` that asserts `APP == config name`, exactly like `resolveAppOrDie`.

- **`storage list`/`inspect` take the resolved `Deployment`, not `(Text, FilePath, Maybe FilePath)`.**
  The plan's signature pre-dated needing the *declared volume set*. Loading the config in `Main`
  (mirroring how `runEnv` resolves identity then calls a body) and passing the `Deployment` to the
  Storage modules is cleaner and gives them the volumes directly.

- **Node path needs a second query, so `extractPVCStatus` is split from enrichment.** A
  `kubectl get pvc -o json` response has no host path; the path is on the bound PV
  (`.spec.local.path`). `extractPVCStatus` (pure, unit-tested) parses everything incl. the bound PV
  name (`prPvName`), leaving `prNodePath` empty; `listAppPVCs` then enriches each bound row via
  `kubectl get pv <name> -o jsonpath` (`readPVNodePath`, best-effort `-`). This keeps the parser
  pure/testable while still populating NODE-PATH live.

- **A workstation `kubectl` cannot reach the k3s API; IAP only forwards SSH (port 22).** EP-33's
  spike reached the cluster via `sudo k3s kubectl` *on the VM*, but `nagarectl` runs locally and
  shells to the local `kubectl`. A `gcloud start-iap-tunnel` to 6443 is refused (the IAP firewall
  only permits 22). The storage commands were therefore verified **end-to-end through the real
  binary** — config load, declared-volume join, the cluster query (which returns gracefully empty
  when the API is unreachable, rendering `MISSING`), the unknown-volume guard (clear error, exit 1),
  and table formatting — with the live-PVC-JSON path covered by the unit-tested `extractPVCStatus`.
  The full on-cluster transcript (real PVC `Bound`, real node path) belongs to EP-37's end-to-end
  examples, which deploy a volume app on the cluster. **Important for EP-37:** to exercise
  `nagarectl` against `nagare-01` you must either run it on the VM or SSH-port-forward 6443 over the
  port-22 IAP tunnel (`ssh -L 16443:127.0.0.1:6443 …`), then point `KUBECONFIG` at a copy of
  `/etc/rancher/k3s/k3s.yaml` with its `server:` rewritten to the forwarded port.

## Decision Log

- Decision: Apply PVC manifests *before* the Knative Service, then wait for the Service to become
  Ready — do **not** block on the PVCs becoming `Bound` before the Service exists.
  Rationale: the single-node k3s cluster satisfies PVCs with the built-in `local-path` StorageClass,
  whose provisioner uses the `WaitForFirstConsumer` binding mode. A PVC under that mode stays in phase
  `Pending` until a pod actually *consumes* it; the disk directory is only carved out when the
  consuming pod is scheduled. If the deploy blocked on `Bound` before the Service (and therefore the
  pod) existed, it would deadlock forever. Applying the PVC first guarantees the object exists when the
  Service's pod schedules; the pod schedule is what flips the PVC to `Bound`. We surface the final
  bound state *after* `waitForReady` returns, as information, never as a gate.
  Date: 2026-06-09

- Decision: The `storage` commands load the typed config (`nagare/Config.hs`) to map an app name to its
  declared volumes, rather than discovering volumes purely from the cluster.
  Rationale: the config is the single source of truth for what volumes an app *should* have (name,
  mount path, size); the cluster only reports what PVCs currently *exist*. Loading the config lets
  `storage list` show the full declared set and flag any volume whose PVC is missing on the cluster,
  and lets `storage inspect APP VOLUME` resolve a volume name to its deterministic PVC name without
  re-deriving the naming convention by hand. This mirrors how `runSiteReleases`/`runSiteRollback`
  in `cli/nagarectl/app/Main.hs` load the config first to obtain identity.
  Date: 2026-06-09

- Decision: Put the shared PVC-discovery logic in a new module `Nagare.Storage.Discover` and design the
  `storage` subparser so a new subcommand can be added without touching `list`/`inspect`.
  Rationale: EP-36 (`docs/plans/36-app-volume-backup-ownership-snapshot-to-gcs-and-retention.md`) will
  add `nagarectl storage snapshot APP VOLUME`, which must discover the same PVCs by the same labels.
  Per MasterPlan Integration Point IP5, EP-35 owns the subparser wiring and the discovery helper; EP-36
  must *extend*, not fork, them. Keeping discovery in its own module with a clean signature lets EP-36
  reuse it directly.
  Date: 2026-06-09

- Decision: `nagarectl deploy` must NEVER delete or recreate a PVC.
  Rationale: deleting a PVC under `local-path` deletes the underlying host directory and therefore all
  the app's data. `kubectl apply` of an existing PVC is idempotent (a no-op for unchanged fields), so
  re-deploy is safe. Retention and deletion of volumes is the explicit concern of EP-34's
  `RetentionPolicy` and EP-36's backup ownership, not of the deploy path.
  Date: 2026-06-09

- Decision: Consume EP-34's renderer and naming/label helpers by their MasterPlan-IP contract rather
  than re-deriving PVC names or label strings in EP-35.
  Rationale: MasterPlan Integration Points IP2/IP3 make EP-34 the owner of the PVC YAML shape, the
  deterministic PVC name (`nagare-vol-<app>-<volume>` form), and the labels
  (`nagare.dev/managed-by`, `nagare.dev/app`, `nagare.dev/volume`). EP-35 queries by those labels and
  applies that YAML; if EP-35 re-derived names it could drift from the renderer. If EP-34's exact
  exported names differ from those assumed here, update Interfaces and Dependencies and the call sites
  accordingly — the *shapes* are fixed by the MasterPlan, only the Haskell identifiers may need a
  rename.
  Date: 2026-06-09

## Outcomes & Retrospective

**Result: both milestones implemented; build clean; all 112 `nagarectl` tests pass (incl. the new
`Nagare.Storage.Discover` group). M1 verified through the real CLI; the storage commands verified
end-to-end through the real binary (the live-PVC-data path is unit-tested + deferred to EP-37).**

- **M1 — deploy provisions PVCs first.** `runDeploy` renders `renderVolumeClaims dep'`, prints each
  PVC block before the Service in `--dry-run`, and (live) applies PVCs → Service → wait Ready →
  `reportPVCs`. The `local-path` `WaitForFirstConsumer` ordering is respected (apply-then-Ready,
  never Bound-first). Proven via the real binary: a volume config emits the PVC manifest first with
  the EP-33 rollout annotations; a no-volume config is byte-compatible (0 PVC blocks, original
  scale annotations). `applyPVCs` reuses idempotent `applyManifests` and the deploy path never
  deletes a PVC (Decision Log hard rule).

- **M2 — `storage list`/`inspect`.** A new `storage` subparser (reusing `StoreCommonOpts`) with the
  shared `Nagare.Storage.Discover` module EP-36 will reuse. `list` joins the config's declared
  volumes to live PVCs (showing `MISSING` for an undeployed volume); `inspect` resolves the volume
  to its `pvcName` and `kubectl describe`s it, erroring clearly on an unknown volume. The PVC
  discovery queries by the IP3 labels (`nagare.dev/app=<app>`), never re-deriving names.

- **Hand-off to EP-36 (IP5).** `Nagare.Storage.Discover` (`appPVCLabelSelector`, `listAppPVCs`,
  `PVCRow`, `pvcName`) and the `storage` subparser are the extension points: EP-36 adds a
  `command "snapshot"` + `StorageSnapshot` constructor and reuses `listAppPVCs`/`appPVCLabelSelector`
  — extend, not fork.

- **Gaps.** The live on-cluster transcript (real `Bound` PVC + node path via `nagarectl`) is
  blocked by the IAP-port-22-only firewall and is deferred to EP-37 (which deploys a real volume app
  and can run `nagarectl` on the VM or via an SSH-forwarded API port — recipe recorded in Surprises).
  The `pvcPhases`/`readPVNodePath` IO paths are not unit-tested (they shell to `kubectl`), matching
  the repo convention that `kubectl` IO is exercised by `--dry-run`/by hand, not in the suite.

