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


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it fully before editing anything.

**Where the code lives.** The deploy CLI is a Haskell project under `cli/nagarectl/`. Its parts:

- `cli/nagarectl/app/Main.hs` — the command-line entry point. It uses the `optparse-applicative`
  library to describe a tree of subcommands and dispatches each to a handler.
- `cli/nagarectl/src/Nagare/Deploy.hs` — the thin layer that shells out to `kubectl` to apply
  manifests and wait for readiness.
- `cli/nagarectl/src/Nagare/Static/Release.hs` and `cli/nagarectl/src/Nagare/Static/Preview.hs` — the
  existing read-only command helpers (release history and previews). They are the templates for the
  new `storage` read commands.
- `cli/nagarectl/nagarectl.cabal` — the build manifest listing the library's exposed modules and
  dependencies, and the test suite.
- `cli/nagarectl/test/Spec.hs` — the test suite, using `tasty` + `tasty-hunit`, that exercises *pure*
  logic (parsing, formatting, naming). Cluster/`kubectl` behavior is exercised by `--dry-run` and by
  hand, not in this suite.
- The typed config model is a separate library under `cli/nagare-dsl/`. The `Deployment` record is in
  `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`; loading a config returns one via
  `Nagare.Dsl.Load.loadDeployment`.

**Key terms, defined in plain language.**

- *Knative Service*: the Kubernetes object that runs an app's container and gives it a URL. On this
  cluster it is referred to in `kubectl` as the short type `ksvc`. The renderer emits it as YAML; the
  deploy applies it.
- *PersistentVolumeClaim (PVC)*: the Kubernetes object that requests a durable disk of a given size.
  Short `kubectl` type: `pvc`. Each declared volume becomes one PVC.
- *StorageClass `local-path`*: the built-in disk provider on this single-node k3s cluster. It satisfies
  a PVC by creating a directory under `/var/lib/nagare/local-path` on the node and mounting it into the
  pod. It uses `WaitForFirstConsumer` binding (see below).
- *`WaitForFirstConsumer`*: a binding mode where the PVC stays `Pending` until a pod that mounts it is
  scheduled. Only then does the provisioner create the directory and flip the PVC's
  `.status.phase` to `Bound`. This is the central gotcha of this plan (see Plan of Work, M1).
- *`cradle`*: the Haskell library this project uses to run subprocesses. The patterns it offers, as
  used in `cli/nagarectl/src/Nagare/Deploy.hs` and `cli/nagarectl/src/Nagare/Static/Preview.hs`:
  `run_ $ cmd "kubectl" & addArgs [...]` runs a command and throws on non-zero exit (use for
  apply/wait); `(exitCode, StdoutRaw out) <- run $ cmd "kubectl" & addArgs [...] & silenceStderr`
  captures stdout and tolerates a non-zero exit (use for `kubectl get -o json`). `StdoutRaw` and
  `StdoutUntrimmed` are output wrappers you pattern-match to get the bytes/text.

**What `runDeploy` does today.** In `cli/nagarectl/app/Main.hs`, `runDeploy :: DeployOpts -> IO ()`
(lines 335–374) loads the `Deployment` with `Load.loadDeployment`, resolves the image tag and build
spec, renders the Knative Service with `renderService dep imageTag`, computes the URL and the
`(name, ns)` identity, then branches:

```haskell
  if dopts ^. #dryRun
    then do
      BC.putStrLn "--- Knative Service manifest ---"
      BC.putStr svcBytes
      forM_ dmBytes $ \dm -> do
        BC.putStrLn "--- DomainMapping manifest ---"
        BC.putStr dm
      TIO.putStrLn ("Build mode: " <> describeBuild spec)
      TIO.putStrLn ("URL: " <> url)
    else do
      if requiresBuild spec
        then do
          configureDockerAuth
          performBuild spec ref
          pushImage ref
        else TIO.putStrLn "Skipping build/push: deploying prebuilt image."
      applyManifests (svcBytes : dmBytes)
      waitForReady name ns
      TIO.putStrLn ("Deployed: " <> url)
```

This is the exact code (`cli/nagarectl/app/Main.hs:356`–`374`) you will extend. `applyManifests` and
`waitForReady` come from `cli/nagarectl/src/Nagare/Deploy.hs`:

```haskell
applyManifests :: [BS.ByteString] -> IO ()
applyManifests = mapM_ applyOne
  where
    applyOne m = withSystemTempFile "nagare-manifest.yaml" $ \fp h -> do
      BS.hPut h m
      hClose h
      run_ $ cmd "kubectl" & addArgs ["apply", "-f", fp]

waitForReady :: Text -> Text -> IO ()
waitForReady name namespace =
  run_ $
    cmd "kubectl"
      & addArgs
        [ "wait", "--for=condition=Ready", "--timeout=300s"
        , "ksvc/" <> T.unpack name, "-n", T.unpack namespace ]
```

(`cli/nagarectl/src/Nagare/Deploy.hs:33`–`54`.)

**The subparser pattern you will copy.** `cli/nagarectl/app/Main.hs:250`–`319` builds the command tree.
The top-level parser combines two commands:

```haskell
    commandParser =
      subparser
        ( command "deploy" deployCmd
            <> command "site" siteCmd
        )
```

and `site` is itself a nested subparser:

```haskell
    siteSubparser =
      subparser
        ( command "deploy" siteDeployCmd
            <> command "releases" siteReleasesCmd
            <> command "rollback" siteRollbackCmd
            <> command "preview" sitePreviewCmd
        )
```

You will add a third top-level `command "storage" storageCmd`, where `storageCmd` is a nested subparser
with `command "list" ...` and `command "inspect" ...`. This is exactly the shape of the `site`
subparser and the deeper `preview` subparser, so EP-36 can later add `command "snapshot" ...` the same
way.

**The read-command templates.** `cli/nagarectl/src/Nagare/Static/Preview.hs:74`–`90` shows
`listPreviews` capturing `kubectl get ... -o name` output, splitting lines, and stripping the
resource prefix:

```haskell
listPreviews :: Text -> Text -> IO [Text]
listPreviews site ns = do
  result <- run ( cmd "kubectl" & addArgs ["get", "ksvc", "-n", T.unpack ns, "-o", "name"]
                    & silenceStderr ) :: IO (ExitCode, StdoutUntrimmed)
  let StdoutUntrimmed out = snd result
      names = map stripResourcePrefix (T.lines out)
  pure (filter (T.isPrefixOf (previewPrefix site)) names)
```

`cli/nagarectl/src/Nagare/Static/Release.hs:207`–`246` shows the table formatter with a `pad` helper
and a `kubectl get ... -o json` reader that decodes with `aeson`:

```haskell
formatReleasesTable :: StaticReleaseLog -> Text
formatReleasesTable logv
  | null (releases logv) = "(no releases recorded)"
  | otherwise = T.unlines (header : map row (releases logv))
  where
    header = "  RELEASE ID        CREATED                SOURCE      URL"
    row r = T.concat [ ..., pad 18 (releaseId r), ... ]
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "
```

```haskell
readReleaseLog :: Text -> Text -> IO (Either Text StaticReleaseLog)
readReleaseLog site ns = do
  (exitCode, StdoutRaw out) <- run $ cmd "kubectl"
    & addArgs ["get", "configmap", T.unpack (configMapName site), "-n", T.unpack ns, "-o", "json"]
    & silenceStderr
  pure $ case exitCode of
    ExitFailure _ -> Right emptyReleaseLog
    ExitSuccess -> extractReleaseLog out
```

You will mirror these three shapes: capture-and-split for the PVC list, `pad`-based table formatting
for `storage list`, and defensive `aeson` walking (like `extractReleaseLog`,
`cli/nagarectl/src/Nagare/Static/Release.hs:180`–`200`) for parsing PVC status JSON.

**App identity.** A Nagare app is a Knative Service named `<app>` in a namespace (default `personal`).
The sibling app-lifecycle plan `docs/plans/30-nagarectl-app-lifecycle-commands.md` describes an
`appIdentityOrDie :: FilePath -> IO (Text, Text)` that loads a `Deployment` and returns
`(serviceNameText name, namespaceText namespace)`, mirroring `siteIdentityOrDie` in `Main.hs:488`. Note
that as of this writing the `Nagare.App` module from EP-30 is **not yet present in the tree**
(`cli/nagarectl/src/Nagare/` currently contains only `Build`, `Deploy`, `Image`, `Server/`, `Static/`).
The `storage` commands therefore load the config themselves via `Load.loadDeployment` and read
`serviceNameText (dep ^. #name)` and `namespaceText (dep ^. #namespace)` directly — exactly the
two accessors `runDeploy` already uses at `Main.hs:353`–`354`. Do not depend on `Nagare.App` existing.

**State of the dependencies right now.** As of authoring, EP-34's `volumes` field is **not yet** on the
`Deployment` record (`cli/nagare-dsl/src/Nagare/Dsl/Types.hs:331`–`348` has no `volumes` field), and
EP-34's renderer/discovery helpers do not yet exist. EP-35 **hard-depends on EP-34**: do not begin M1's
implementation until EP-34 has merged the `volumes` field and the PVC renderer. If you must start
early, the Interfaces and Dependencies section records the exact signatures to code against; treat any
mismatch as a coordination point with EP-34 and update this plan.


## Plan of Work

The work is two milestones. M1 makes `nagarectl deploy` provision PVCs in the correct order. M2 adds
the read-only `storage list` and `storage inspect` commands. Each is independently verifiable.

### Milestone 1 — Deploy-time PVC provisioning

**Scope.** Teach `nagarectl deploy` to render an app's PVC manifests, print them before the Service in
`--dry-run`, and apply them before the Service in a live deploy, with the `WaitForFirstConsumer`
ordering handled correctly. At the end of M1, a `Deployment` that declares volumes deploys its PVCs
and then its Service; a `Deployment` with no volumes deploys exactly as today.

**The ordering, explained for a novice.** The naive instinct is "create the disk, wait for it to be
ready, then create the app." That is wrong here. The `local-path` provider does not create the disk
directory until a pod that mounts it is scheduled — this is the `WaitForFirstConsumer` mode. So the PVC
sits in phase `Pending` with no disk behind it until the Service's pod comes up. The correct order is:

1. `kubectl apply` the PVC manifests. The PVC *objects* now exist (phase `Pending`). No disk yet.
2. `kubectl apply` the Knative Service. Knative schedules a pod that mounts the PVCs.
3. When that pod schedules, the provisioner creates each disk directory and flips each PVC to `Bound`.
4. `waitForReady` blocks until the Service is Ready (which only happens once the pod — and thus the
   mounts — are healthy).
5. *After* `waitForReady` returns, optionally read each PVC's phase and print a confirmation line. By
   then they are `Bound`.

If you instead waited for `Bound` between steps 1 and 2, the deploy would hang forever, because nothing
consumes the PVC yet. This is why the Decision Log records "apply PVCs before Service, then wait for
Ready (not Bound-first)."

**The edits.**

*Edit 1 — add the cluster helpers.* In `cli/nagarectl/src/Nagare/Deploy.hs`, add and export two
functions next to `applyManifests`/`waitForReady`. Reuse the existing `applyManifests` for the apply
itself (it already writes each manifest to a temp file and `kubectl apply -f`s it, which is idempotent
and exactly what PVCs need). Add:

```haskell
-- | Apply the rendered PVC manifests for an app. A no-op when the list is empty
-- (the common, zero-volume case). Idempotent: re-applying an existing PVC is a
-- no-op for unchanged fields and never recreates the underlying disk.
applyPVCs :: [BS.ByteString] -> IO ()
applyPVCs [] = pure ()
applyPVCs pvcs = applyManifests pvcs

-- | After the Service is Ready, read each PVC's phase for an informational
-- summary. Returns (pvcName, phase) pairs; a missing PVC yields ("<name>",
-- "NotFound"). Never throws and never gates the deploy.
pvcPhases :: Text -> [Text] -> IO [(Text, Text)]
pvcPhases ns names = traverse one names
  where
    one n = do
      (code, StdoutRaw out) <- run $ cmd "kubectl"
        & addArgs [ "get", "pvc", T.unpack n, "-n", T.unpack ns
                  , "-o", "jsonpath={.status.phase}" ]
        & silenceStderr
      pure $ case code of
        ExitSuccess  -> (n, decodePhase out)
        ExitFailure _ -> (n, "NotFound")
    decodePhase = T.strip . TE.decodeUtf8
```

(Import `Data.Text.Encoding qualified as TE` and `System.Exit (ExitCode (..))` at the top of
`Deploy.hs`; both patterns already appear in `Static/Release.hs`.) Export `applyPVCs` and `pvcPhases`
from the module's export list at `cli/nagarectl/src/Nagare/Deploy.hs:8`–`12`.

Note we deliberately do **not** write a `waitForPVCBound` that blocks before the Service: the Decision
Log explains why. If, after building EP-34's spike (EP-33), it turns out the chosen StorageClass binds
immediately (`Immediate` mode) rather than `WaitForFirstConsumer`, a pre-Service Bound wait could be
added — but `local-path` on this cluster is `WaitForFirstConsumer`, so we apply-then-Ready and report
phases afterward.

*Edit 2 — render and order the PVCs in `runDeploy`.* In `cli/nagarectl/app/Main.hs`, in `runDeploy`,
after the existing `let` block that binds `svcBytes`, `dmBytes`, `url`, `name`, `ns`, add a binding for
the PVC manifests produced by EP-34's renderer for this `Deployment`. Per MasterPlan Integration Point
IP2, EP-34 exports a function that renders an app's standalone PVC manifests; reference it as
`renderVolumeClaims dep` (confirm the exact name EP-34 ships — see Interfaces and Dependencies):

```haskell
      pvcBytes = renderVolumeClaims dep   -- [] when the app declares no volumes
```

Then change the two branches. In `--dry-run`, print the PVCs *before* the Service:

```haskell
  if dopts ^. #dryRun
    then do
      forM_ pvcBytes $ \pvc -> do
        BC.putStrLn "--- PersistentVolumeClaim manifest ---"
        BC.putStr pvc
      BC.putStrLn "--- Knative Service manifest ---"
      BC.putStr svcBytes
      forM_ dmBytes $ \dm -> do
        BC.putStrLn "--- DomainMapping manifest ---"
        BC.putStr dm
      TIO.putStrLn ("Build mode: " <> describeBuild spec)
      TIO.putStrLn ("URL: " <> url)
    else do
      ...
      applyPVCs pvcBytes              -- (1) PVCs first
      applyManifests (svcBytes : dmBytes)  -- (2) then the Service (unchanged)
      waitForReady name ns           -- (3) wait for Ready (unchanged)
      reportPVCs ns pvcBytes dep     -- (4) informational phase summary
      TIO.putStrLn ("Deployed: " <> url)
```

`reportPVCs` is a tiny local helper in `Main.hs` that, when `pvcBytes` is non-empty, gathers the PVC
names for `dep` (via EP-34's name helper or `Nagare.Storage.Discover` from M2) and prints a line per
volume such as `Volume data: pvc nagare-vol-myapp-data is Bound`. When `pvcBytes` is empty it prints
nothing, preserving the exact zero-volume output. Because `applyPVCs []` and an empty `forM_` are
no-ops, an app with no volumes produces byte-identical output and behavior to today — verify this in
M1.4.

**Commands to run (M1).**

```bash
cd cli/nagarectl
cabal build
```

```bash
# zero-volume app: output must be identical to before this change
cd /Users/shinzui/Keikaku/bokuno/nagare/cluster/examples/<some-no-volume-app>
nagarectl deploy --dry-run --ghc-env <env-file>
```

```bash
# volume-bearing app: PVC manifests print before the Service
cd <a config that declares a volume>
nagarectl deploy --dry-run --ghc-env <env-file>
```

**Acceptance (M1).** `cabal build` is clean. The volume-bearing `--dry-run` prints one
`--- PersistentVolumeClaim manifest ---` block per declared volume *before* the
`--- Knative Service manifest ---` block. The no-volume `--dry-run` is unchanged. A live deploy of a
volume-bearing app applies the PVCs, then the Service, reaches Ready, and prints a per-volume
`... is Bound` line. See Validation and Acceptance for exact transcripts.

### Milestone 2 — `storage list` and `storage inspect`

**Scope.** Add a new `storage` subparser with two read-only subcommands and the shared discovery
helper EP-36 will reuse. At the end of M2, `nagarectl storage list APP` prints a table of the app's
volumes and their cluster status, and `nagarectl storage inspect APP VOLUME` prints the full detail of
one volume's PVC.

**New modules.** Create a `Nagare.Storage` namespace:

- `cli/nagarectl/src/Nagare/Storage/Discover.hs` — the shared helper. Holds the pure logic
  (PVC-name/label construction, JSON status extraction, table formatting) plus the small `kubectl` IO
  to list and read PVCs. This is the module EP-36 reuses. Per MasterPlan IP3, it must query PVCs by the
  Nagare-managed labels EP-34 stamps, never re-derive names by hand. Key functions (signatures in
  Interfaces and Dependencies): `appPVCLabelSelector`, `listAppPVCs`, `readPVCStatus`,
  `extractPVCStatus`, `formatStorageTable`.
- `cli/nagarectl/src/Nagare/Storage/List.hs` — `runStorageList`: loads the config, lists the app's PVCs
  via `Nagare.Storage.Discover`, joins each declared volume to its PVC status, and prints the table.
- `cli/nagarectl/src/Nagare/Storage/Inspect.hs` — `runStorageInspect`: loads the config, resolves the
  `VOLUME` argument to its deterministic PVC name (via the EP-34 name helper re-exported from
  `Discover`), and shells out to `kubectl describe pvc <name> -n <ns>` (streaming through `run_`, like
  `deletePreview`), exiting with a clear error if the volume is not declared in the config.

**The `storage list` table.** Mirror `formatReleasesTable`. Columns: `VOLUME`, `PVC`, `SIZE`,
`STATUS`, `NODE-PATH`. `VOLUME` and `SIZE` come from the loaded config (the declared volume name and
`quantityText size`); `PVC` is the deterministic name; `STATUS` is the PVC's `.status.phase` (or
`MISSING` when the PVC does not exist on the cluster — important so a declared-but-never-deployed volume
is visible); `NODE-PATH` is the host directory the disk lives at, read from the PVC's
`local-path`-provisioner annotation (the provisioner records the selected path on the bound PV; if not
yet bound, print `-`). Use the `pad` helper exactly as `formatReleasesTable` does.

**The discovery query.** Per MasterPlan IP3 the labels are `nagare.dev/app=<app>` (plus
`nagare.dev/managed-by` and a per-volume `nagare.dev/volume`). `listAppPVCs` runs:

```haskell
kubectl get pvc -n <ns> -l nagare.dev/app=<app> -o json
```

and `extractPVCStatus` walks `.items[]`, pulling for each `.metadata.name`,
`.metadata.labels["nagare.dev/volume"]`, `.spec.resources.requests.storage`, `.status.phase`, and
`.spec.volumeName` (to look up the node path) — defensively, in the style of `extractReleaseLog`
(`cli/nagarectl/src/Nagare/Static/Release.hs:180`–`200`): pattern-match `Aeson.Object`/`Aeson.Array`,
return `Left` on a malformed shape, never crash.

**Subparser wiring.** In `cli/nagarectl/app/Main.hs`:

- Add `Storage StorageCommand` to the `Command` sum type (`Main.hs:121`–`128`), where
  `data StorageCommand = StorageList StorageOpts | StorageInspect StorageOpts Text` and
  `data StorageOpts = StorageOpts { appArg :: String, file :: FilePath, ghcEnv :: Maybe FilePath }`.
- Add `command "storage" storageCmd` to the top-level `commandParser` (`Main.hs:258`–`262`).
- Define `storageCmd` as a nested subparser mirroring `siteCmd`/`siteSubparser`:

```haskell
    storageCmd =
      info (storageSubparser <**> helper)
        (fullDesc <> progDesc "Inspect an app's persistent volumes")
    storageSubparser =
      subparser
        ( command "list" storageListCmd
            <> command "inspect" storageInspectCmd
        )
```

  `storage list` takes a positional `APP` (`strArgument (metavar "APP")`) plus the shared `fileOpt`,
  `ghcEnvOpt`. `storage inspect` adds a second positional `VOLUME`. Design note for EP-36: a third
  `command "snapshot" storageSnapshotCmd` slots into `storageSubparser` with no change to `list` or
  `inspect` — this is the IP5 extension point.
- Add `Storage` cases to the `main` dispatch (`Main.hs:326`–`333`) calling the new `runStorageList` /
  `runStorageInspect`, loading identity via `Load.loadDeployment` and `dieT (Load.renderLoadError err)`
  on failure, exactly as `runSiteReleases` does.

**Register the modules.** Add `Nagare.Storage.Discover`, `Nagare.Storage.List`, and
`Nagare.Storage.Inspect` to the library `exposed-modules` in `cli/nagarectl/nagarectl.cabal:32`–`45`.
The needed deps (`aeson`, `cradle`, `nagare-dsl`, `text`, `bytestring`, `temporary`) are already in the
library stanza.

**Tests.** In `cli/nagarectl/test/Spec.hs`, add a `Nagare.Storage.Discover` test group covering the
*pure* pieces (the IO/`kubectl` path is exercised by hand and via M2's transcript):

- `appPVCLabelSelector "myapp" @?= "nagare.dev/app=myapp"`.
- `extractPVCStatus` on a small hand-written `kubectl get pvc -o json` fixture returns the expected
  `[(volume, pvcName, size, phase, nodePath)]`.
- `extractPVCStatus` on a `{"items":[]}` response returns `Right []`.
- `extractPVCStatus` on malformed JSON returns a `Left`.
- `formatStorageTable` on a known list produces the expected header and a `MISSING`-status row for a
  declared volume with no PVC.

**Commands to run (M2).**

```bash
cd cli/nagarectl
cabal build
cabal test
```

```bash
nagarectl storage list myapp --ghc-env <env-file>
nagarectl storage inspect myapp data --ghc-env <env-file>
```

**Acceptance (M2).** `cabal test` is green including the new `Nagare.Storage.Discover` group.
`nagarectl storage list myapp` prints the table with one row per declared volume; `storage inspect`
prints the `kubectl describe` of the resolved PVC and errors clearly on an unknown volume name. See
Validation and Acceptance for transcripts.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless a `cd` is
shown. `kubectl` must target the `tan-nb-exp` cluster only (this is the cluster the repo's `.envrc`
configures; per `CLAUDE.md` no other GCP project may be touched). The `--ghc-env <env-file>` flag (or
the `NAGARE_GHC_ENVIRONMENT` env var) points the config loader's `runghc` at the `nagare-dsl` package;
use whatever value the existing deploy flow uses in your environment.

1. Confirm EP-34 has landed the `volumes` field and renderer:

```bash
grep -n "volumes" cli/nagare-dsl/src/Nagare/Dsl/Types.hs
grep -rn "renderVolumeClaims\|pvcName\|nagare.dev/volume" cli/nagare-dsl/src/
```

   You should see a `volumes` field on `Deployment` and an exported PVC renderer + name/label helpers.
   If not, EP-34 is incomplete — pause M1 and coordinate (see Context and Orientation).

2. M1 — edit `cli/nagarectl/src/Nagare/Deploy.hs` (add `applyPVCs`, `pvcPhases`, update exports and
   imports), then `cli/nagarectl/app/Main.hs` (`runDeploy`: add `pvcBytes`, print before Service in
   dry-run, apply before Service live, `reportPVCs`). Build:

```bash
cd cli/nagarectl
cabal build
```

   Expected: `Linking ...` with no errors.

3. M1 dry-run check (no cluster contact). Run against a config that declares a volume and one that does
   not; compare to the transcripts in Validation and Acceptance.

4. M2 — create the three `Nagare.Storage.*` modules, register them in `nagarectl.cabal`, wire the
   `storage` subparser in `Main.hs`, and add the tests in `test/Spec.hs`. Build and test:

```bash
cd cli/nagarectl
cabal build
cabal test
```

   Expected: all test groups pass, including `Nagare.Storage.Discover`.

5. Live verification (M1 + M2) against `tan-nb-exp`: deploy a volume-bearing app, then list and inspect
   its storage. See Validation and Acceptance for the exact transcripts.


## Validation and Acceptance

Acceptance is phrased as behavior you can observe.

**M1 — dry-run shows PVCs before the Service (volume-bearing app).** With a config declaring one volume
named `data` of size `1Gi` mounted at `/data`:

```text
$ nagarectl deploy --dry-run
--- PersistentVolumeClaim manifest ---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nagare-vol-myapp-data
  namespace: personal
  labels:
    nagare.dev/managed-by: nagarectl
    nagare.dev/app: myapp
    nagare.dev/volume: data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
--- Knative Service manifest ---
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: myapp
  ...
Build mode: docker build -f Dockerfile .
URL: https://myapp.personal.apps.example.com
```

The exact PVC YAML bytes are owned by EP-34; what M1 must prove is the **ordering** — every
`--- PersistentVolumeClaim manifest ---` block appears before `--- Knative Service manifest ---`.

**M1 — no-volume app is unchanged.** For a config with no volumes, the `--dry-run` output is identical
to before this plan: it starts with `--- Knative Service manifest ---` and contains no PVC block. Prove
this by capturing the output before and after the change and diffing:

```bash
git stash                                  # revert to pre-change tree
nagarectl deploy --dry-run > /tmp/before.txt
git stash pop
cabal build
nagarectl deploy --dry-run > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt        # expect: no differences
```

**M1 — live deploy provisions PVCs first, then the app.** Against `tan-nb-exp`:

```text
$ nagarectl deploy
Skipping build/push: deploying prebuilt image.
persistentvolumeclaim/nagare-vol-myapp-data created
service.serving.knative.dev/myapp created
service.serving.knative.dev/myapp condition met
Volume data: pvc nagare-vol-myapp-data is Bound
Deployed: https://myapp.personal.apps.example.com
```

The `persistentvolumeclaim/... created` line (from `kubectl apply`) appears **before**
`service.serving.knative.dev/myapp created`. After `waitForReady` returns, the per-volume
`... is Bound` line confirms the disk bound once the pod scheduled. Re-running `nagarectl deploy`
prints `persistentvolumeclaim/nagare-vol-myapp-data unchanged` (idempotent — no recreate, no data
loss).

You can independently confirm the PVC bound and the data path:

```bash
kubectl get pvc -n personal -l nagare.dev/app=myapp
# NAME                    STATUS   VOLUME   CAPACITY   STORAGECLASS   AGE
# nagare-vol-myapp-data   Bound    pvc-...  1Gi        local-path     30s
```

**M2 — `storage list`.**

```text
$ nagarectl storage list myapp
  VOLUME    PVC                      SIZE   STATUS   NODE-PATH
  data      nagare-vol-myapp-data    1Gi    Bound    /var/lib/nagare/local-path/pvc-...
```

A volume declared in the config but not yet deployed shows `STATUS = MISSING` and `NODE-PATH = -`,
proving the command joins the declared set to the live cluster rather than only listing what exists.

**M2 — `storage inspect`.**

```text
$ nagarectl storage inspect myapp data
Name:          nagare-vol-myapp-data
Namespace:     personal
StorageClass:  local-path
Status:        Bound
Volume:        pvc-...
Capacity:      1Gi
Access Modes:  RWO
...
```

```text
$ nagarectl storage inspect myapp nosuchvol
nagarectl: app myapp declares no volume named 'nosuchvol'
```

(the second exits non-zero.)

**Tests.**

```bash
cd cli/nagarectl
cabal test
```

```text
nagarectl
  ...
  Nagare.Storage.Discover
    appPVCLabelSelector builds the app selector:           OK
    extractPVCStatus reads items into rows:                OK
    extractPVCStatus of empty items is []:                 OK
    extractPVCStatus of malformed JSON is Left:            OK
    formatStorageTable marks a missing PVC:                OK

All N tests passed
```

These pure tests fail before the modules exist and pass after, demonstrating the logic beyond mere
compilation.


## Idempotence and Recovery

Every step in this plan is safe to repeat.

- **Re-deploying is idempotent and never destroys data.** `applyPVCs` reuses `applyManifests`, which is
  `kubectl apply -f` — applying an already-present PVC reports `unchanged` and changes nothing on disk.
  The deploy path NEVER issues `kubectl delete` against a PVC, so a re-deploy can never wipe a volume.
  This is a hard rule (Decision Log): deleting a `local-path` PVC deletes the host directory and all
  data; deletion/retention is EP-34/EP-36's concern, not the deploy's.
- **The read commands are read-only.** `storage list` and `storage inspect` only run `kubectl get` /
  `kubectl describe`; they make no changes and can be run any number of times.
- **A half-finished deploy is recoverable by re-running.** If `nagarectl deploy` fails after applying
  the PVCs but before the Service is Ready (for example a bad image), simply fix the cause and re-run:
  the PVCs already exist (apply is a no-op), and the Service is re-applied. No manual cleanup is needed
  and no data is at risk.
- **A `Pending` PVC after a failed deploy is expected, not an error.** Because of
  `WaitForFirstConsumer`, a PVC whose Service never scheduled a healthy pod stays `Pending`. That is
  normal; the next successful deploy schedules a pod and binds it. `storage list` shows `Pending` (not
  `MISSING`) in this state, distinguishing "PVC exists, waiting for a consumer" from "PVC never
  created."
- **Cluster isolation.** All `kubectl` calls target the active `tan-nb-exp` context configured by the
  repo's `.envrc`; no command in this plan targets another GCP project, and there is no `gcloud` use
  here (the GCS snapshot work is EP-36's).


## Interfaces and Dependencies

**Libraries used.** `optparse-applicative` (the command tree, in `Main.hs`); `cradle` (subprocess
calls to `kubectl`, already a dependency); `aeson` (parsing `kubectl get -o json`); `text`,
`bytestring`, `temporary` (already used by the library). All are already listed in
`cli/nagarectl/nagarectl.cabal`; no new dependency is added.

**Consumed from EP-34** (`docs/plans/34-typed-volume-and-mount-model-with-pvc-and-volumemount-renderer.md`),
via MasterPlan Integration Points IP1/IP2/IP3. These must exist before M1 is implemented; the exact
Haskell identifiers are EP-34's to fix — the signatures below are the contract this plan codes against,
and any renaming must be reflected here and at the call sites:

- The `volumes` field on `Deployment` (`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`), defaulting to the
  empty list so existing configs are unaffected (IP1), and accessors such as `volumeNameText` and
  `mountPathText`.
- `renderVolumeClaims :: Deployment -> [ByteString]` — render the standalone PVC manifests for an app's
  declared volumes; the empty list for a zero-volume app (IP2). (Confirm EP-34's exact name; if it
  differs, e.g. `renderPVCs`, update the import and the `pvcBytes` binding in `runDeploy`.)
- The deterministic PVC name helper, `pvcName :: Text -> Text -> Text` taking the app name and volume
  name and returning e.g. `nagare-vol-<app>-<volume>` (IP3), and the label keys
  `nagare.dev/managed-by`, `nagare.dev/app`, `nagare.dev/volume`. `Nagare.Storage.Discover` re-exports
  `pvcName` and the label constants so the storage commands and EP-36 query by them, never re-derive.

**Consumed from the existing CLI:**

- `Nagare.Dsl.Load.loadDeployment :: FilePath -> IO (Either LoadError Deployment)` and
  `Nagare.Dsl.Load.renderLoadError :: LoadError -> Text` — load the typed config and report errors.
- `Nagare.Dsl.Types.serviceNameText`, `Nagare.Dsl.Types.namespaceText`,
  `Nagare.Dsl.Types.quantityText` — accessors for identity and sizes.
- `Nagare.Deploy.applyManifests` — reused by `applyPVCs`.
- The `optparse-applicative` helpers already in `Main.hs`: `fileOpt`, `ghcEnvOpt`, `provisionGhcEnv`,
  `dieT`, `orDie`, `defaultConfigFile`.

**New, end of M1.** In `cli/nagarectl/src/Nagare/Deploy.hs` (exported):

- `applyPVCs :: [ByteString] -> IO ()` — apply rendered PVC manifests; no-op on the empty list.
- `pvcPhases :: Text -> [Text] -> IO [(Text, Text)]` — namespace, PVC names → `(name, phase)` pairs for
  the post-Ready summary; never throws.

In `cli/nagarectl/app/Main.hs`: an updated `runDeploy` and a local
`reportPVCs :: Text -> [ByteString] -> Deployment -> IO ()` informational helper (no-op when there are
no volumes).

**New, end of M2.** A new `Nagare.Storage` namespace under `cli/nagarectl/src/Nagare/Storage/`, all
registered in `cli/nagarectl/nagarectl.cabal`:

- `cli/nagarectl/src/Nagare/Storage/Discover.hs` (the IP5 shared helper EP-36 reuses):
  - `appPVCLabelSelector :: Text -> Text` (pure, tested) — `"nagare.dev/app=" <> app`.
  - `data PVCRow = PVCRow { prVolume :: Text, prName :: Text, prSize :: Text, prStatus :: Text,
    prNodePath :: Text }`.
  - `extractPVCStatus :: ByteString -> Either Text [PVCRow]` (pure, tested) — defensive `aeson` walk of
    a `kubectl get pvc -o json` list response.
  - `listAppPVCs :: Text -> Text -> IO (Either Text [PVCRow])` — namespace, app → run
    `kubectl get pvc -n <ns> -l <appPVCLabelSelector app> -o json` and `extractPVCStatus` it.
  - `readPVCStatus :: Text -> Text -> IO (Either Text PVCRow)` — namespace, PVC name → single PVC.
  - `formatStorageTable :: [Volume] -> [PVCRow] -> Text` (pure, tested) — join the declared volumes to
    the discovered rows and render the `VOLUME PVC SIZE STATUS NODE-PATH` table with a `pad` helper;
    a declared volume with no matching row renders `MISSING` / `-`.
  - re-exports of EP-34's `pvcName` and the label constants.
- `cli/nagarectl/src/Nagare/Storage/List.hs`:
  - `runStorageList :: Text -> FilePath -> Maybe FilePath -> IO ()` — app, config file, ghc-env; loads
    the config, `listAppPVCs`, `formatStorageTable`, prints.
- `cli/nagarectl/src/Nagare/Storage/Inspect.hs`:
  - `runStorageInspect :: Text -> Text -> FilePath -> Maybe FilePath -> IO ()` — app, volume, config
    file, ghc-env; loads the config, resolves the volume to its PVC name (errors if the config declares
    no such volume), and streams `kubectl describe pvc <name> -n <ns>` via `run_`.

In `cli/nagarectl/app/Main.hs`: a `Storage StorageCommand` constructor on `Command`, the
`StorageCommand`/`StorageOpts` types, the `storage` subparser (`list`, `inspect`), and the `main`
dispatch cases. The subparser is structured so **EP-36**
(`docs/plans/36-app-volume-backup-ownership-snapshot-to-gcs-and-retention.md`) can add a
`command "snapshot" ...` and a `StorageSnapshot` constructor without modifying `list`/`inspect` — this
is Integration Point IP5, owned here and extended (not forked) there.

**Soft dependency on EP-33** (`docs/plans/33-knative-pvc-enablement-spike-and-cluster-feature-flags.md`):
a *live* end-to-end deploy of a volume-bearing app needs the Knative `config-features` flags EP-33
enables on the cluster. All of M1's `--dry-run` behavior and all of M2's pure tests are verifiable
without the cluster; only the live transcripts in Validation and Acceptance require EP-33 to have run.
