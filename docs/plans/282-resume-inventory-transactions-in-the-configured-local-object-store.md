---
id: 282
slug: resume-inventory-transactions-in-the-configured-local-object-store
title: "Resume inventory transactions in the configured local object store"
kind: exec-plan
created_at: 2026-11-24T18:12:35Z
intention: "intention_01m89e375xepdrdsg6wtwcspdk"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-24T18:12:35Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-25T03:26:37Z
      mode: "implement"
      note: "M1 implemented; M2 native confirmation on a disposable ir54 context"
---

# Resume inventory transactions in the configured local object store

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

A local Nagare context (`mode=local`) can keep its inventory history in the cluster's MinIO object
store instead of a workstation directory (`NAGARE_INVENTORY_STORE=object`, set by
`nagarectl inventory store migrate --to object --yes`). The inventory history is the journal and
head that record every reviewed change Nagare applies. When an apply stops halfway, for example
because the registry was unreachable while an image was being published, the transaction stays
"active" in that history and blocks every later reviewed change until `nagarectl inventory resume TX
--yes` finishes it.

On such a context, resume does not work. During Kotei's hosted delivery rehearsal
(`mori://shinzui/kotei/okf/friction-log/concepts/FRIC-108`), a stopped image publication left an
active transaction; `inventory close` found the operation safe to retry and pointed the operator to
resume, and resume refused with:

```text
StoreIoError: inventory object store URL must start with gs://
```

The operator had no supported way to finish the transaction. This plan answers improvement request
IR-54 ([docs/improvement-requests/resume-inventory-transactions-in-the-configured-local-object-store.md](../improvement-requests/resume-inventory-transactions-in-the-configured-local-object-store.md)).

After this plan, `nagarectl inventory resume TX --yes` on a local object-store context opens that
context's MinIO history and continues the original transaction under its original review, exactly as
it already does for a workstation-directory history or a cloud context's GCS history. The same fix
lets `platform bootstrap plan`, `platform transition plan`, `kubeconfig recover` and context moves
select the object store on such a context instead of failing the same way. The recovery rules of a
cloud context's first foundation transaction, and every check that a transaction belongs to this
context and this review, are unchanged.

To see it working: on a disposable local context with an object-store history, stop the local
registry, apply an image publication review (it stops), start the registry again, and run
`nagarectl inventory resume TX --yes`. It completes, and `nagarectl inventory status --json` shows no
active transaction (`inventory store status` cannot show it for a schema 2 head; see Surprises &
Discoveries).


## Progress

- [x] M1: store selection keeps a local context's object store for foundation selection and for
  resume; the new `S3 store` unit test fails before the fix and passes after; the `S3 store`,
  `inventory object operations`, `cluster foundation inventory`, `inventory transactions`,
  `artifact inventory adapter` and `close by per-operation proof (ADR 26)` groups pass;
  `just gate-commit` green.
  Passed 2026-11-24 (commit 27b3a468). With `selectResumeStore` moved and the guards unchanged,
  the new case failed: `but got: Left (StoreConditionFailed "context \"ir54\" not found ...")`;
  with `/= InventoryStoreGcs` it passes. `just gate-commit` green in 128 s, running the whole
  suite (every named group, 0 failures). The command audit had to register `selectResumeStore`
  as a library call and refresh the catalogue snapshot (FRIC-23).
- [x] M2: native confirmation on a disposable local MinIO context with the CLI built at the M1
  revision: a stopped image publication resumes to the same transaction, review and image digest
  (IR-54 AC-1); a publication killed after the registry accepted it converges on resume and a second
  resume writes nothing (AC-2); a transaction ID that is not this context's refuses before any write
  (AC-3).
  Passed 2026-11-24 on the CLI at 27b3a468 (fast record green), context `ir54` bootstrapped by the
  drill (FRIC-22) on its own Colima profile (`--vz-rosetta`) and migrated to
  `http://minio.nagare-system.svc.cluster.local:9000/nagare-inventory/ir54`; torn down afterwards.
  AC-1: with the registry stopped, apply of `ir54-probe:v1` stopped `tx-3d06a453…0ddc0d` at the
  adapter preflight (`KnownNoEffect … artifact observation unavailable`); `inventory status` showed
  it active, `resume-required`. Resume from MinIO printed `converged tx-3d06a453…` (review digest
  `3d06a453…`), no active transaction remained, and the registry serves
  `sha256:4184f6ec…44ecd8`, the digest the reviewed artifact address binds. AC-2: apply of
  `ir54-probe:v4` frozen during `inventory-artifact-transport.sh publish` and killed (05:08:16)
  after the registry's only manifest PUT for v4 (05:08:08, 201); `tx-90d0b53a…b48697` stayed
  active; the first resume printed `converged`, the second `converged` again, with no further PUT,
  the registry catalog unchanged and `inventory status` identical apart from its observation
  times. AC-3: `inventory resume tx-000…000 --yes` refused with `inactive-transaction: transaction
  is not active in the store head`; status (less observation times) and catalog unchanged. A
  pre-operation stop (`tx-8bb5ba9a…`, killed during preflight) also resumed to `converged`.
- [x] M3: landed (`just gate-fast`, `just mutation-check`, `just land`, full gate green) and IR-54
  marked completed with this plan as its target plan. (2026-11-25: landed 7cad8b43; gate-fast green;
  mutation-check proved 0 of 206 records; post-land full gate green in 1391 s.)


## Surprises & Discoveries

- `inventory store status` cannot show the active transaction of a current history: since EP-231
  (commit 15779151) a head is schema version 2 once the journal holds a convergence event, and the
  command still reports every `schema > 1` head as `"state": "unsupported-schema"` without
  `activeTransaction` (`cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Store.hs`). M2 first read
  a stopped transaction as settled because of it, and then observed through `inventory status
  --json` (`.activeTransaction`, `.transactionStatus`). The fix is out of this plan's scope and is
  reported to the operator.
- The plan's substrate steps (`just local-up`, `local-bootstrap`, `local-minio`) do not bootstrap a
  dev-tree context on their own; M2 used the drill bootstrap (FRIC-22) and needed a Colima profile
  with Rosetta for the linux/amd64 auth images (FRIC-26), `colima delete --data` to replace a
  profile (FRIC-25) and a manually started registry forward after a failed first run (FRIC-24).


## Decision Log

- Decision: Fix the store kind check in `selectFoundationStore` itself, not only in the resume path.
  Rationale: `selectFoundationStore` treats every store that is not the workstation directory as GCS,
  so `platform bootstrap plan`, `platform transition plan`, `kubeconfig recover` and context moves
  reach the same GCS discovery on an object-store context. Only a cloud context with a GCS store has
  a first foundation transaction that may live in a workstation journal before its remote store
  exists; a local context's selected store is its only authority. Fixing the one predicate fixes
  every caller of the same defect without adding a new behaviour.
  Date: 2026-11-24
- Decision: Move `foundationResumeTarget` from the executable
  (`cli/nagarectl/app/Nagare/Cli/Inventory/Workflow.hs`) into the library as
  `Nagare.Inventory.Command.Open.selectResumeStore`.
  Rationale: the test suite cannot import executable modules (`nagarectl-test` builds from `test/`
  against the library in `src/`). Moving the function lets a unit test drive resume store selection
  directly, so reverting the guard fails a test rather than only a native run (ADR 25).
  Date: 2026-11-24


## Outcomes & Retrospective

`nagarectl inventory resume` on a local context with an object-store history now opens that
history and finishes the stopped transaction under its original review. Foundation store
selection treats only a GCS context as having a workstation foundation journal, so bootstrap and
transition planning, `kubeconfig recover` and context moves no longer reach GCS discovery on such
a context. A unit test in the `S3 store` group proves the selection, and a disposable MinIO
context confirmed IR-54's three criteria (27b3a468, landed with 7cad8b43). Two things remain.
Kotei must confirm on the next released CLI. And `inventory store status` still hides the active
transaction of every schema 2 head (Surprises & Discoveries), reported to the operator and not
fixed here. No ADR changes: the rule narrows existing behaviour within ADR 22 and ADR 26. Friction:
FRIC-23 accepted (a recurrence of FRIC-21's hidden audit error), FRIC-24 accepted (the drill's
forward is not restarted after a failed first run), FRIC-25 resolved (the plan's Colima teardown
now deletes the data disk), FRIC-26 accepted (a disposable profile needs `--vz-rosetta` for the
linux/amd64 auth images; the plan's command now says so).


## Context and Orientation

All paths are relative to the repository root, `/Users/shinzui/Keikaku/bokuno/nagare`.

**Inventory store kinds.** `cli/nagarectl/src/Nagare/Target/Kinds.hs` defines
`data InventoryStoreKind = InventoryStoreLocal | InventoryStoreGcs | InventoryStoreObject`.
`InventoryStoreLocal` is a directory on the workstation,
`${XDG_STATE_HOME:-~/.local/state}/nagare/CONTEXT/inventory`. `InventoryStoreGcs` is a cloud
context's Google Cloud Storage bucket. `InventoryStoreObject` is an S3-compatible store in a local
cluster (MinIO), addressed by `NAGARE_INVENTORY_STORE_URL` such as
`http://minio.nagare-system.svc.cluster.local:9000/nagare-inventory/CONTEXT`.
`effectiveInventoryStore` in `cli/nagarectl/src/Nagare/Target.hs` (around line 462) gives the kind a
context really uses: a local context yields `InventoryStoreObject` or `InventoryStoreLocal`, never
GCS; a cloud context yields its configured kind, and loading a cloud profile with
`NAGARE_INVENTORY_STORE=object` is refused (same file, around line 850). The object store is
described for users in `docs/user/local-development.md`, section "Optional: the inventory in the
cluster object store".

**Opening a store.** `openTargetStore` and `openTargetStoreObserving` in
`cli/nagarectl/src/Nagare/Inventory/Command/Open.hs` open the store `effectiveInventoryStore`
names. For a GCS or object store they first refuse when the workstation directory still holds
history that was not migrated to that store ("local inventory history exists; migrate it before
selecting another store"). `openTargetStoreReadOnly` in
`cli/nagarectl/src/Nagare/Inventory/Store/Target.hs` does the same selection without creating
anything. These functions already handle all three kinds correctly.

**Foundation store selection, where the defect is.** A cloud context's first transaction (the "cloud
foundation": its GCP APIs, state buckets and Pulumi stack) runs before the GCS bucket that will hold
its inventory exists, so that transaction is journalled in the workstation directory and moved to
GCS afterwards. `selectFoundationStore` in `cli/nagarectl/src/Nagare/Inventory/Command/Open.hs`
(around line 129) decides, before bootstrap work, whether a cloud context's authority is still that
workstation journal or already the GCS history. It discovers the bucket through
`Remote.remoteDiscoveryOps`, which accepts only `gs://` URLs. Its guard reads:

```haskell
selectFoundationStore target
  | effectiveInventoryStore (target ^. #profile) == InventoryStoreLocal = pure (Right target)
  | otherwise = do ... GCS discovery ...
```

so an object-store context falls into GCS discovery and fails with
`inventory object store URL must start with gs://` (raised in
`cli/nagare-core/src/Nagare/Inventory/Store/Gogol.hs` and
`cli/nagare-core/src/Nagare/Inventory/Store/ObjectOps.hs`). Its callers are
`foundationStageTarget` in `cli/nagarectl/app/Nagare/Cli/Bootstrap/Foundation.hs`, which in turn is
called by bootstrap planning and applying (`cli/nagarectl/app/Nagare/Cli/Bootstrap/Review.hs`), the
release transition (`cli/nagarectl/app/Nagare/Cli/Commands/Transition.hs`, around line 114),
`kubeconfig recover` (`cli/nagarectl/app/Nagare/Cli/Commands/Host.hs`, around line 224), and resume.

**Resume store selection.** `runInventoryResume` in
`cli/nagarectl/app/Nagare/Cli/Inventory/Workflow.hs` (around line 289) calls
`foundationResumeTarget target transaction` (around line 320) and resumes against the target it
returns. That function returns the target unchanged only for `InventoryStoreLocal`; for any other
kind it calls `foundationStageTarget`, and if the selected store is not GCS it requires the exact
active initial cloud foundation review (`mode == Cloud`, a `nagare-bootstrap:` payload identity, no
base revisions, only the `platform:cloud-foundation` scope, only `CloudFoundationExecutor`
operations) and otherwise refuses with "local inventory recovery requires the exact active initial
cloud foundation review". An object-store context therefore fails twice over: in discovery today,
and in this check even if discovery were skipped. The check was written for EP-153
([docs/plans/153-close-managed-command-coverage-for-the-inventory-release.md](153-close-managed-command-coverage-for-the-inventory-release.md),
commit `cf269e72`), before the object store existed. Released v0.28.2 has the same code; the live
failure was seen on v0.24.5.

**What resume itself checks.** `resumeInventoryWithFactoryTakeover` in
`cli/nagarectl/src/Nagare/Inventory/Command.hs` (around line 744) opens the store, reads the head,
loads the published review whose digest is the transaction ID without its `tx-` prefix, and calls
the journal's resume. `cli/nagarectl/src/Nagare/Inventory/Execute/Transaction.hs` (around line 283)
returns `Converged` for a transaction the journal already settled and refuses any other transaction
that is not the head's active one with "transaction is not active in the store head". The store is
bound to the context and provider project (`ContextBinding`), so a transaction from another
context's history is never the active one here. None of this depends on the store kind, and this plan
does not change it.

**Image publication recovery.** The image publication adapter already resumes a lost
acknowledgement by observing the registry and never publishing twice; see the tests "EP-237: a lost
acknowledgement resumes by observing the registry and never publishes again" and "EP-237: a failure
that may have had an effect and left nothing is safe to retry" in
`cli/nagarectl/test/InventoryArtifactSpec.hs` (group `artifact inventory adapter`). The journal's
store contract over S3 is proved in `cli/nagarectl/test/Nagare/Test/S3Store.hs` (group `S3 store`)
against an in-memory S3 with ETag conditions.

**Relevant ADRs.**
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) establishes
the typed inventory and its single journalled history per context, which is why a stopped
transaction blocks later changes until it is resumed or closed.
[ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) says a stopped
transaction ends only through per-operation proof (resume, or `inventory close`); this plan restores
the resume exit on object-store contexts and does not touch the proofs.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires a
test to find the defect and a native run only to confirm it, which shapes M1 before M2.
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) is unaffected:
the change applies only to stores a local context uses, and a cloud context's GCS path is unchanged.


## Plan of Work

**M1: select the configured object store.** In
`cli/nagarectl/src/Nagare/Inventory/Command/Open.hs`, change the first guard of
`selectFoundationStore` from `== InventoryStoreLocal` to `/= InventoryStoreGcs`, and update its
comment: only a GCS context can have a first foundation transaction journalled in the workstation
directory; a local context's workstation or object store is its only authority, and
`openTargetStore` already refuses unmigrated workstation history before an object store is used.

In the same module add and export `selectResumeStore :: ActiveTarget -> Text -> IO ActiveTarget`,
moved from `foundationResumeTarget` in `cli/nagarectl/app/Nagare/Cli/Inventory/Workflow.hs`. Its
first guard becomes `effectiveInventoryStore (target ^. #profile) /= InventoryStoreGcs = pure target`.
The GCS branch keeps its body: call `selectFoundationStore` (die on `Left`), return the selection
when it is GCS, and otherwise apply the exact initial cloud foundation review check unchanged. Use
the library's `dieText` in place of the executable's `dieT` and keep every refusal's text. Move the
comment above `foundationResumeTarget` with it. Re-export `selectResumeStore` from
`cli/nagarectl/src/Nagare/Inventory/Command.hs` next to `selectFoundationStore`, replace the call in
`runInventoryResume` with `Inventory.selectResumeStore target transaction`, delete
`foundationResumeTarget`, and drop any imports in `Workflow.hs` that become unused (the build runs
with warnings as errors in the gate). `runInventoryResume`'s post-resume GCS migration is unchanged:
it runs only when the active context is GCS and the selection was the workstation journal.

Add one test case to `s3StoreTests` in `cli/nagarectl/test/Nagare/Test/S3Store.hs`, named
"a local context's object store is its own foundation and resume store (IR-54)". Inside a fresh
temporary directory, with `withTestEnv` from `cli/nagarectl/test/Nagare/Test/Support/Environment.hs`
setting `XDG_STATE_HOME` and `XDG_CONFIG_HOME` to subdirectories of it and unsetting
`CLOUDSDK_CORE_PROJECT`, build `ActiveTarget context profile` where `profile` is `initProfile` from
`Nagare.Test.Support.Profiles` with `#mode .~ Local`, `#inventoryStore .~ InventoryStoreObject` and
`#inventoryStoreUrl .~ "http://127.0.0.1:19000/nagare-inventory/ir54"`. Assert that
`selectFoundationStore target` returns `Right target`, that `selectResumeStore target
"tx-<any 64 hex digits>"` returns `target`, that the same two calls on the workstation-directory
variant (`#inventoryStore .~ InventoryStoreLocal`) return it unchanged, and that the state directory
still does not exist afterwards (selection creates nothing). Before the fix the first assertion fails:
with no stored context profile, `selectFoundationStore` returns a `Left` refusal on its way to GCS
discovery, and with one it returns the `gs://` error. The GCS behaviour is already covered by the
`chooseHistoryAuthority` cases in `cli/nagarectl/test/InventoryObjectOpsSpec.hs` and by
`cli/nagarectl/test/InventoryFoundationSpec.hs`; run them unchanged.

**M2: native confirmation.** Native behaviour changes (which store resume opens), so per the project
rules one native confirmation on a disposable local context follows the unit test. It uses a Docker
daemon that hosts no other cluster, so stopping its registry affects nothing else, and it is thrown
away afterwards. It proves the three IR-54 criteria against real MinIO and a real registry; the steps
are in Concrete Steps. A disposable local context needs only a green `just gate-fast` record at the
revision (`docs/runbooks/before-a-native-run.md`, section 3).

**M3: land and close the request.** Run the landing gates, land, and mark IR-54 completed with this
plan as `targetPlan`, with a line in `docs/improvement-requests/log.md`. The change ships in the
next release; Kotei's rehearsal confirms it on that released CLI, which is what IR-54 AC-1 names.


## Concrete Steps

M1, from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
cabal test nagarectl-test --test-option=-p --test-option='/S3 store/'
```

Before the code change, with only the new test added, expect one failure in the new case, of the form:

```text
a local context's object store is its own foundation and resume store (IR-54): FAIL
  expected: Right (ActiveTarget ...)
   but got: Left (StoreConditionFailed ...)
```

After the change, the `S3 store` group passes. Then, from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
just haskell-style-check
just gate-commit
```

`just gate-commit` selects the touched test groups itself and ends with each step `ok`. If it does
not select them, run them by name:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
for group in 'S3 store' 'inventory object operations' 'cluster foundation inventory' \
  'inventory transactions' 'artifact inventory adapter' 'close by per-operation proof'; do
  cabal test nagarectl-test --test-option=-p --test-option="/$group/" || break
done
```

Commit with a Conventional Commit message and the plan trailer:

```text
fix(inventory): resume transactions in a local context's object store

Foundation store selection treated every store that is not the workstation
directory as GCS, so resume, bootstrap and transition planning on a local
context with NAGARE_INVENTORY_STORE=object failed with "inventory object
store URL must start with gs://". Only a GCS context has a first foundation
journalled on the workstation; a local context's store is its own authority.

ExecPlan: docs/plans/282-resume-inventory-transactions-in-the-configured-local-object-store.md
```

M2, on a disposable local context. Keep the commands in a script file outside the repository (for
example in a scratch directory), run with `bash -euo pipefail`, as
`docs/runbooks/before-a-native-run.md` section 4 asks. First the substrate, with a Docker daemon of
its own (Colima shown; any daemon that hosts no other k3d cluster works) and the CLI built at the M1
revision:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
just gate-fast
colima start --profile ir54 --vz-rosetta  # the auth images are linux/amd64
export DOCKER_HOST="unix://$HOME/.colima/ir54/docker.sock"
export PATH="$(dirname "$(cd cli/nagarectl && cabal list-bin nagarectl)"):$PATH"
nagarectl context create ir54 --mode local \
  --registry-host k3d-registry.localhost:5000 \
  --base-domain 127-0-0-1.sslip.io \
  --target-platform linux/arm64 \
  --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups
export NAGARE_CONTEXT=ir54
just local-up && just local-bootstrap && just local-minio
nagarectl inventory store migrate --to object --yes
nagarectl inventory store status
```

Use `linux/amd64` on Intel/AMD hosts. The last command must name the
`http://minio.nagare-system.svc.cluster.local:9000/nagare-inventory/ir54` store with no active
transaction.

The host's port 5000 may belong to macOS AirPlay, so read the registry from inside its container, as
`scripts/inventory-artifact-transport.sh` does. Define these helpers at the top of the script:

```bash
manifest_digest() { # TAG -> sha256:..., empty when absent
  docker exec k3d-registry.localhost wget -S -O /dev/null \
    --header='Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "http://localhost:5000/v2/ir54-probe/manifests/$1" 2>&1 \
    | sed -n 's/^[[:space:]]*Docker-Content-Digest:[[:space:]]*\(sha256:[0-9a-f]*\).*/\1/p' | head -n 1
}
catalog() { docker exec k3d-registry.localhost wget -q -O - http://localhost:5000/v2/_catalog; }
```

AC-1, a stopped publication resumes. `WORK` is an absolute directory outside the repository:

```bash
WORK="$HOME/.local/state/nagare/ir54-native"; mkdir -p "$WORK"
docker pull --platform linux/arm64 busybox:1.37
docker tag busybox:1.37 k3d-registry.localhost:5000/ir54-probe:v1
docker save k3d-registry.localhost:5000/ir54-probe:v1 -o "$WORK/probe-v1.tar"
nagarectl app image-plan --archive "$WORK/probe-v1.tar" \
  --destination k3d-registry.localhost:5000/ir54-probe:v1 --key ir54-probe-v1 \
  --save-plan "$WORK/review-v1"
docker stop k3d-registry.localhost
nagarectl inventory apply "$WORK/review-v1" --yes || echo "apply stopped as intended"
nagarectl inventory store status --json > "$WORK/stopped.json"
docker start k3d-registry.localhost
TX=$(jq -r '.. | .activeTransaction? // empty' "$WORK/stopped.json" | head -1)
nagarectl inventory resume "$TX" --yes
nagarectl inventory store status --json > "$WORK/resumed.json"
```

Read the field names from the actual `store status --json` output and adjust the `jq` path if it
differs; record the transaction ID shown. Pass when: `stopped.json` names an active transaction `TX`
and the apply printed a stop rather than a refusal before admission; resume completes the same `TX`
without a takeover; `resumed.json` shows no active transaction; the review digest is `TX` without its
`tx-` prefix both times; and `manifest_digest v1` prints the reviewed manifest digest, which
`nagarectl inventory status --json` reports for the publication and `app image-plan` printed.

If the stopped registry makes the apply refuse before it admits a transaction (no active transaction
in `stopped.json`), the fixture did not reach resume: record that in Surprises & Discoveries and use
the AC-2 interruption for AC-1 as well.

AC-2, a publication interrupted after the registry accepted it. nagarectl publishes by running the
payload's `inventory-artifact-transport.sh` as a child process, after the journal has recorded the
operation as started. Freeze nagarectl as soon as that child exists: the child finishes the push
while its parent cannot record the result. Once the registry serves the manifest, kill the frozen
apply. Only the PID this script started is signalled; `pgrep -P` is used only to observe its child.

```bash
docker tag busybox:1.37 k3d-registry.localhost:5000/ir54-probe:v2
docker save k3d-registry.localhost:5000/ir54-probe:v2 -o "$WORK/probe-v2.tar"
nagarectl app image-plan --archive "$WORK/probe-v2.tar" \
  --destination k3d-registry.localhost:5000/ir54-probe:v2 --key ir54-probe-v2 \
  --save-plan "$WORK/review-v2"
nagarectl inventory apply "$WORK/review-v2" --yes & APPLY=$!
until pgrep -P "$APPLY" -f inventory-artifact-transport >/dev/null; do sleep 0.01; done
kill -STOP "$APPLY"
until [ -n "$(manifest_digest v2)" ]; do sleep 0.2; done
kill -9 "$APPLY"; wait "$APPLY" || true
nagarectl inventory store status --json > "$WORK/killed.json"
manifest_digest v2 > "$WORK/v2-before-resume.txt"
```

If the transport child was not seen before the apply finished (no active transaction in
`killed.json`), repeat with a new tag and key (`v3`, `ir54-probe-v3`). If the transport turns out not
to be a direct child, record that in Surprises & Discoveries and freeze the apply instead when
`ps -o pid=,command= -p "$(pgrep -P "$APPLY" | tr '\n' ',' | sed 's/,$//')"` first shows a
push. Then resume twice:

```bash
TX2=$(jq -r '.. | .activeTransaction? // empty' "$WORK/killed.json" | head -1)
nagarectl inventory resume "$TX2" --yes
nagarectl inventory store status --json > "$WORK/settled.json"
nagarectl inventory resume "$TX2" --yes
nagarectl inventory store status --json > "$WORK/settled-again.json"
cmp "$WORK/settled.json" "$WORK/settled-again.json"
```

Pass when the first resume settles `TX2` without publishing again, `manifest_digest v2` still
prints the digest in `v2-before-resume.txt` and that digest is the reviewed one, the second resume
reports the transaction as already converged, and `cmp` prints nothing.

AC-3, a transaction that is not this context's. Use a well-formed ID that is not the head's active
transaction, for example `tx-` followed by 64 zeros, and record status and the registry catalog
before and after:

```bash
nagarectl inventory store status --json > "$WORK/before-foreign.json"
catalog > "$WORK/catalog-before.json"
nagarectl inventory resume "tx-$(printf '0%.0s' $(seq 64))" --yes || echo "refused as intended"
nagarectl inventory store status --json > "$WORK/after-foreign.json"
catalog > "$WORK/catalog-after.json"
cmp "$WORK/before-foreign.json" "$WORK/after-foreign.json"
cmp "$WORK/catalog-before.json" "$WORK/catalog-after.json"
```

Pass when resume refuses with `transaction is not active in the store head` and both `cmp` calls
print nothing. Then tear down the disposable substrate. `just local-down` refuses once a context
has inventory history, so delete the whole Docker daemon, which holds the cluster, registry and
MinIO, and the context's workstation files:

```bash
colima delete --profile ir54 --data --force
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/nagare/ir54" "$WORK"
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/ir54.env"
```

Record the transaction IDs, review digests, manifest digests and refusal line in M2's Progress entry.

M3, from the repository root with a clean tree:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
just gate-fast
just mutation-check HEAD origin/master
just land HEAD
```

`just mutation-check` proves only the mutation records whose files the range touched; if it selects
none, there is nothing to run. A surviving record means a test no longer catches a known bug: fix the
test before landing. Then set `status: completed` and `targetPlan:
docs/plans/282-resume-inventory-transactions-in-the-configured-local-object-store.md` in IR-54's
frontmatter and add a dated line to `docs/improvement-requests/log.md`, in a `docs:` commit.


## Validation and Acceptance

Required acceptance is IR-54's three criteria.

AC-1: on a local context with `NAGARE_INVENTORY_STORE=object`, `nagarectl inventory resume TX --yes`
opens the context's MinIO history and completes the stopped transaction `TX` under its original
review; the transaction ID, review digest and published manifest digest are the same before and
after recovery. Proved in M2; the store selection that makes it possible is proved by M1's unit test.

AC-2: a publication interrupted after the registry accepted the image converges once on resume, the
active transaction clears, and a repeated resume changes neither the history nor the registry.
Proved in M2; the adapter's observe-before-republish rule is the existing
`artifact inventory adapter` lost-acknowledgement test, run unchanged in M1.

AC-3: the workstation-directory store and the cloud foundation path keep their checks. M1 runs the
`inventory object operations`, `cluster foundation inventory`, `inventory transactions` and
`close by per-operation proof (ADR 26)` groups unchanged and they pass; the new test asserts that a
workstation-directory context is still returned unchanged. On MinIO, M2 shows a foreign transaction
ID refused before any history or registry write.

The change is not complete on compilation: the new `S3 store` test must fail before the fix and pass
after, and M2 must pass on real MinIO.


## Idempotence and Recovery

M1 is a code change; rerunning the tests is harmless. In M2 every step runs on a disposable context
and Docker daemon. A resume that stops again can be rerun with the same transaction ID; if resume
cannot finish, `nagarectl inventory close TX --review DIGEST` ends the transaction by per-operation
proof (ADR 26). If any guard or check refuses unexpectedly, stop, record the refusal, and do not
work around it (project rule). If the background apply in AC-2 wins the race, repeat with a new key;
earlier publications stay accepted and do not interfere. The teardown at the end of M2 removes
everything it created: the Colima profile holds the cluster, registry and MinIO, and the context's
workstation state and context file are deleted by path. Check `nagarectl context list` (or the
`contexts/` directory) first so only `ir54` is removed, and reselect your usual context afterwards.


## Interfaces and Dependencies

At the end of M1, `cli/nagarectl/src/Nagare/Inventory/Command/Open.hs` exports, and
`cli/nagarectl/src/Nagare/Inventory/Command.hs` re-exports:

```haskell
-- | Select authority once before bootstrap work (unchanged signature).
-- A local context's workstation or object store is returned as is.
selectFoundationStore :: ActiveTarget -> IO (Either StoreError ActiveTarget)

-- | The store a resume of TRANSACTION opens. A local context's store is
-- returned as is; a GCS context's first foundation transaction resumes from
-- its workstation journal only under its exact initial review.
selectResumeStore :: ActiveTarget -> Text -> IO ActiveTarget
```

`foundationResumeTarget` no longer exists in `cli/nagarectl/app/Nagare/Cli/Inventory/Workflow.hs`.
No dependency, wire format, journal format or command-line interface changes.
