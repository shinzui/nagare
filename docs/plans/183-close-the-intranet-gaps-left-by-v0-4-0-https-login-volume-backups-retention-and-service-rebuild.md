---
id: 183
slug: close-the-intranet-gaps-left-by-v0-4-0-https-login-volume-backups-retention-and-service-rebuild
title: "Close the intranet gaps left by v0.4.0: HTTPS login, volume backups, retention and service rebuild"
kind: exec-plan
created_at: 2026-10-10T02:43:33Z
intention: "intention_01m3m6hh7temkvtd7cgzkb3r15"
master_plan: "docs/masterplans/24-operate-nagare-as-a-team-run-workplace-intranet-paas.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-10T02:43:33Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-10T02:58:24Z
      mode: "update"
      note: "Operator accepted extending the DB producer for volumes; M3 starts with a slice checkpoint"
---

# Close the intranet gaps left by v0.4.0: HTTPS login, volume backups, retention and service rebuild

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

## Purpose / Big Picture

Nagare v0.4.0 reached its production-readiness goal for one operator: databases are backed up hourly
off the cluster with escrowed signing keys, data survived the destruction of the cluster, and node
and PostgreSQL upgrades are proven safe. The operator now wants to run the work intranet on it. The
release notes (`docs/releases/v0.4.0.md`, "Unmet production targets") list three targets v0.4.0
did not meet:

- D3: HTTPS routes and protected browser login were never exercised; the acceptance fixture was
  HTTP-only.
- D2: application volumes are outside the hourly recovery-point objective.
- D4: there are no recovery-time or retention targets.

A fourth gap follows from D4. After losing the VM, Nagare can recover the data but cannot bring the
same context back into service, because planning refuses to recreate an accepted durable resource.

After this plan, an operator can do four things they cannot do today:

- Open an intranet app at `https://app.<base-domain>/` in an ordinary browser with no certificate
  warning, be sent to the login portal, sign in, and reach the app. A user without a grant gets
  403.
- Read in `nagarectl server status` that every backup-included application volume is graded
  against the same recovery-point objective as the databases.
- See backups past their agreed retention reported, and remove them with one reviewed command that
  can never remove the newest usable recovery point.
- Rebuild the whole service on a new VM after losing the old one, through a reviewed procedure,
  inside a recovery-time target the operator has agreed and that a drill has timed.

The proof is two native runs, listed in M5. One is local (k3d on the cp3 workstation) and one is in
the cloud (a fresh GCP context). Each exercises all four behaviours and records evidence beside the
v0.4.0 evidence. The next release's notes then drop D2, D3 and D4 from "Unmet production targets".

Team operation is out of scope. Several operators, named-reviewer approval and shared deployment
material remain MasterPlan 24's later streams, and this plan does not change them. Moving an
existing v0.4.0 installation to the release that carries this work is EP-172's reviewed release
transition (`docs/plans/172-rehearse-candidate-upgrades-of-an-inventory-context-instead-of-rebuilding-it.md`).
This plan only makes sure its changes are covered by that transition's compatibility table.


## Progress

- [ ] M1. On a fresh local inventory context, the acceptance run fails unless the fixture's
  protected route answers over HTTPS with the context's certificate trusted:
  - an anonymous request gets 302 to the login portal;
  - a scripted login with a granted user gets 200;
  - a revoked grant gets 403.

  The deploy waits for the route's certificate to be Ready. The docs no longer call local mode
  HTTP-only or show the refused direct `context create --force` form.
  - [x] (2026-10-10) Code: the readiness fix, the `nagare-harness route-check` stage with docs, and
    two mutation records. `just gate-fast` is green, and both records were proven locally with
    their exact patterns.
  - [ ] A fresh local bootstrap uses locally published MinIO images by default (Surprises,
    2026-10-10).
  - [x] (2026-10-10) Full gate and `gate-verify` at the landed revision. Then, on a fresh local context, the
    route-check run and its `--ca /dev/null` negative run.
    - [x] (2026-10-10) M1–M4 landed at d42913c9 (full gate green, mutation sweep 184 killed, 0
      survivors). A fresh local context on cp3 bootstrapped at d42913c9 and deployed scenario-a.
      The first route-check run refused the wrong CA, then got 502 "no backend configured" for
      the protected route (Surprises, 2026-10-10, enforcer).
    - [x] (2026-10-10) The enforcer re-reads its backend map, and route-check waits for a new
      route's 502 to clear (0212a55e).
    - [x] (2026-10-10) The fixed enforcer image rolled onto cp3 through a reviewed bootstrap
      (two updates: the enforcer Service and the bootstrap stamp). route-check passed: wrong
      CA refused, anonymous 302 to `/_nagare/login`, granted login 200, 403 after revoke. The
      `--ca /dev/null` run failed with curl 77, a named certificate failure. Evidence and
      drivers: [cp3-route-check](../audits/intranet-gaps-2026-10-10/cp3-route-check/).
- [ ] M2. (Targets recorded 2026-10-10: UC-3, ADR 28.) The operator's recovery-time and retention targets are recorded (EP-162 M1, or this plan's
  proposed defaults confirmed). `server status` reports scheduled database backups past retention
  as WARN. `db prune-scheduled-backups --save-plan` reviews them, and applying the review removes
  them. Recovery-model scenarios prove that a prune stopped at any operation closes by
  per-operation proof and never removes the newest verified recovery point.
  - [x] (2026-10-10) On the worker branch, `gate-fast` green:
    - the retention policy (`Nagare.Inventory.BackupRetention`), bound in the release (ADR 28
      amendment);
    - the admission re-check (`retention-policy`) and the `server status` retention row;
    - the reviewed prune on MinIO and GCS: generation-pinned deletes, absence proved only by the
      JSON API's 404;
    - one recovery Job for any stopped prune;
    - batch ingestion, `db backup-receipts --all` (ADR 22 amendment, operator-approved);
    - tolerance for runs uploaded after the newest accepted run.
  - [x] (2026-10-10) Bounded scope and Job growth. Review k+1 retires a converged run's receipt
    scope and its prune or recovery scopes. Review k+2 collects the prune and recovery Jobs, and
    k+3 the ingestion Job. Cleanup-only reviews are supported. `gate-fast` is green on the worker
    branch.
  - [ ] The operator's review of the 30-day noncurrent GCS window. The empty-GCS-prefix message
    is deferred.
  - [ ] Full gate and land; then a local check of the WARN row and the prune.
- [ ] M3. (Decision recorded 2026-10-09: extend the database producer.) Every backup-included
  volume of a context has a scheduled producer with signed receipts. Its
  freshness is graded against the context's objective in `server status`. A restore of the newest
  receipt into a new PVC matches the source.
  - [x] (2026-10-10) Slice checkpoint PASSED. It needed only the dump container, the source kind,
    a PVC-only source check and the status row, plus a name check in the signing-key template. It
    needed no new ingestion, acceptance or restore-authority semantics.
  - [x] (2026-10-10) Producer (`nagare-volbackup-<app>-<volume>`), signed v5 volume receipts,
    graded status rows, removal of the legacy `volumes/` probe, and docs. `gate-fast` is green on
    the worker branch.
  - [x] (2026-10-10) Volume receipt ingestion: the database ingestion with the StatefulSet pin
    optional (three pins), `storage backup-receipts APP VOLUME (--backup-id ID | --all)`. Database
    Job bytes are unchanged (19ea76b9, records bb799664).
  - [x] (2026-10-10) Rebuild from an accepted scheduled volume run: recovery point kind
    `scheduled-volume`, `verifyIngestedVolumeRun`, `inventory rebuild-decisions --volume-run`
    (882ef5aa, records 3c5cd341).
  - [x] (2026-10-10) Scratch restore of an accepted scheduled volume run: `storage restore APP
    VOLUME RUN_ID --scheduled-run`, verified against the run's ingestion record. It shares the
    scratch claim and Job with the manual-snapshot restore (666cca43, records d76d9477).
  - [x] (2026-10-10) Retention, prune, recovery and cleanup for volume runs (M2 step 6): siblings
    keyed by schedule; `storage prune-scheduled-backups` and `storage recover-scheduled-prune`
    through `PruneSource`; a retention row per volume (0d8f21f2, records f9397612).
  - [x] (2026-10-10) Model scenario: a backup-included volume's producer created and its CronJob
    updated under every fault placement (ffa0b2df).
  - [x] (2026-10-10) A stopped volume prune keeps its reviewed exit after an application deploy:
    the prune pins the claim incarnation and the schedule spec, not the app scope revision. The
    recovery review requires only its own prune scope and the run's receipt scope unchanged
    (ece0a769, record 1ccce070).
  - [ ] Deferred to the next release: key-kind-aware escrow and offline verification of volume
    runs (only runs never ingested need it), and volumes of standalone services and workers.
  - [ ] Full gate and land; local check (row within one period, degradation when the newest
    upload is deleted, byte-identical restore).
- [ ] M4. A reviewed operation recreates a missing durable member from its predecessor's verified
  recovery point, recording the lineage. It is proven in the recovery model under faults first.
  On a local context whose cluster was deleted, the documented rebuild brings the fixture back into
  service with its data, and the time is recorded.
  - [x] (2026-10-10) PostgreSQL rebuild: `inventory rebuild-decisions`, `inventory rebuild`,
    `db restore-rebuilt`, a model scenario under every fault placement, five refusal mutations,
    the ADR 27 amendment and the runbook. `gate-fast` is green on the worker branch.
  - [x] (2026-10-10) ClickHouse and Redis restore from escrow-verified scheduled receipts,
    application volumes from verified manual snapshots (`storage restore-rebuilt`), and an
    offline object-store option for verification. Nine mutation records in all; `gate-fast` is
    green on the worker branch.
  - [ ] Full gate and `gate-deep` (Admission changed), batched with M2; then the local
    cluster-delete rehearsal on cp3, timed.
- [ ] M5. Native run N1 (local, cp3) and native run N2 (fresh cloud context, Let's Encrypt
  certificate) pass all M1–M4 checks. That includes a manual passkey login in a browser that trusts
  the certificate, and a VM-loss rebuild within the agreed recovery time. Evidence is under
  `docs/audits/`, and the next release's notes no longer list D2, D3 or D4.


## Surprises & Discoveries

- Observation (M3 slice checkpoint): passed. `server status` grades verified uploads still
  awaiting ingestion (decision D1), so the slice needed no ingestion. The volume expectation is
  derived from the accepted CronJob's bytes, exactly as for databases.
- Observation (M3): the signing-key generator recognised only `nagare-dbbackup-<db>-signing`. A
  volume schedule's Secret carries `nagare.dev/volume-backup` and is accepted only under the
  `nagare-volbackup-` prefix.
- Observation (M3): retention for volume receipts (M2 step 6) depends on volume ingestion, because
  `BackupRetention` grades only accepted receipts.
- Observation (M3): a rebuild from an ingested volume run needs no escrowed key. The ingestion
  record pins the receipt digest, the archive checksum and their exact versions, the same trust
  model as a manual snapshot. Escrow matters only for runs never ingested.
- Observation (M3): the rebuild restore Job checks only digests and versions, so a scheduled
  volume archive (tar.gz) restores through it unchanged.
- Observation (M3): every retention check keyed siblings by source scope, and an application scope
  holds one schedule per backed-up volume, so one volume's runs would have been ranked against
  another's. Siblings are now keyed by `scheduled.backup.schedule`; databases are unaffected.
- Observation (M3): the database prune treats a run ingested under an older source revision as
  stale. An application's scope revision moves with every deploy, so a volume run is instead
  current while taken from the current claim incarnation under the current schedule.
- Observation (M3): apply-time prune evidence required the policy scope's only CronJob; an
  application can hold several. It now uses the run's own schedule.
- Observation (M3): with a Namespace in the model's application scope, a namespace deleted outside
  Nagare refused planning with no exit. Production keeps the namespace in the foundation scope, so
  the model fixture drops that one edge instead.
- Observation (M3, coordinator review): the first volume prune pinned its application scope's
  revision, so an ordinary deploy left a failed prune with no reviewed exit (ADR 26). Not deferred.
- Observation (M2/M3): the recovery review required the whole accepted head to equal the failed
  review's base, but closing that prune changes the head, so `db recover-scheduled-prune` could
  never be reviewed. No test exercised that CLI check. Fixed for both source kinds by
  `scheduledPruneRecoveryBasis`.
- Observation (M3): while a stopped prune's transaction is open, planning any other review refuses
  (`active-transaction`). After close, deploys and other volumes' prunes proceed; a failed prune
  Job observes as present and is never retired by another schedule's cleanup.

- Observation (M2): a run was accepted only through one review per run (`db backup-receipts NAME
  --backup-id JOB_UID`), and a prune refused while any listed run was un-ingested. At the hourly
  objective that meant about 96 reviews a day by hand. Fixed by batch ingestion.
- Observation (M2): a prune Job that failed before deleting anything left the run marked pruned
  with both objects live. The old recovery accepted only "archive gone, receipt left", so every
  later prune refused. This was pre-existing and wedged retention. The new recovery Job finishes
  that state.
- Observation (M2): the cloud prune was never supported. The CLI refused GCS, and the GCS receipt
  recovery Job was `exit 1`.
- Observation (M2): the backup bucket is versioned (EP-99), so a pruned generation stays
  noncurrent for 30 days, plus GCS soft delete, before it is destroyed. For personal data, backup
  copies can therefore outlive the 30-day retention by about a month. This is left for the
  operator to review.
- Observation (M2): a receipt scope cannot be retired in its prune's review
  (`dangling-reference`). A scope cannot be replaced and retired in one review. Collection needs a
  retirement accepted in an earlier review. Bounded growth therefore lags one or two prune
  reviews.
- Observation (M2): a test provider that fixed its present set before apply recorded no
  incarnations at convergence, so a retirement silently retained nothing. World observation must
  read the store at call time.
- Observation (M2): the forward scheduled prune already existed (keep-last-N, MinIO only) before
  it was deferred in `699ae909`. M2 restored it on the new policy.

- Observation (M4): the model found 25 runs with no exit. In each, the cluster was lost while an
  accepted durable member had never been recorded, because a create's response was lost or a
  review was closed, so the rebuild could name no predecessor.
  Evidence: the fast tier on the parent tree of the worker branch's first M4 commit.
  Fix: such members rebuild `fresh` only; a recovery point needs a recorded predecessor.
- Observation (M4): restoring into a live database is deferred in v0.4.0, so the rebuild's data
  restore is a separate reviewed step (`db restore-rebuilt`). It loads only into an empty
  database, in one transaction.
- Observation (M4): `InventoryRecoveryModelSpec.hs` and `Suite.hs` were at their 1000-line caps.
  Ingestion moved to `Nagare.Test.Model.Ingest`, and the rebuild tests are nested under the
  incarnation group.
- Observation (M4): in local mode the bucket is the in-cluster MinIO, which is lost with the
  cluster. Verification can read an offline copy, but the restore Jobs download pinned versions.
  The rehearsal must therefore copy MinIO's data directory (not `mc mirror`, which loses versions)
  back into the new cluster's MinIO before restoring.
- Observation (M4): an application scope owns its databases and volumes, so a rebuild recreates
  the app's workloads before the restore runs. Nothing holds the app's writers off. Every restore
  refuses a target that already holds data, so an early write makes the restore refuse instead of
  mixing data. The runbook says to restore straight away and keep traffic away.
- Observation (M4): manual volume snapshot receipts are not signed. A rebuild checks them against
  the inventory's record of the snapshot and its exact object versions instead (ADR 27
  amendment).

- Observation: the inventory deploy reported a protected route as served while it answered only
  plain HTTP.
  Evidence: Knative 1.22's domainmapping reconciler (`knative-v1.22.0`,
  `pkg/reconciler/domainmapping/reconciler.go`) runs with the default `http-protocol: Enabled`. It
  marks a DomainMapping whose certificate is not Ready as `CertificateProvisioned=True`, reason
  `HTTPDowngrade`, with `status.url` `http://`, so the mapping reads `Ready=True`. Both the
  readiness wait (`kubectl wait --for=condition=ready`) and `knativeReady` passed. The new world
  test failed on `0aed15ec`: the create completed and the object read Present while its
  certificate was pending.
- Observation: a Service's default `<name>.<namespace>.<base-domain>` host has the same downgrade.
  The Knative Service object does not show it; only its Route does. Protected and custom-domain
  routes are DomainMappings and are covered. Default hosts are not yet held to the certificate
  wait.
- Observation: the release fixture's protected route uses the enforcer's built-in form
  (`/_nagare/login`, CSRF cookie `__Host-nagare_csrf`), not a portal. route-check drives that form
  and reports a portal redirect as unsupported.
- Observation (2026-10-10): the default local MinIO images (`quay.io/minio/minio` and
  `quay.io/minio/mc` digests in `cluster/local/minio/minio.yaml` and
  `cli/nagarectl/src/Nagare/Inventory/Components/LocalObjectStore.hs`) answer 401 to anonymous
  pulls (`skopeo inspect` gives "unauthorized"). A fresh local bootstrap works only through
  `scripts/publish-local-minio-images.sh` and the `NAGARE_LOCAL_MINIO_IMAGE` /
  `NAGARE_LOCAL_MC_IMAGE` overrides. The operator chose to fix this here, as part of M1, because
  N1 needs fresh local contexts.

- Observation (2026-10-10, enforcer): every route protected after the platform bootstrap answered
  502 "no backend configured for host …". The enforcer (`cli/nagare-access/app/Main.hs`) read
  `/etc/nagare-access/backends/backends.json` once at startup, and an application deploy changes
  only the `nagare-access-backends` ConfigMap, so the running enforcer never learned the route.
  The mounted file had the route within about a minute; the process did not. No earlier run
  checked a protected route over HTTP after a deploy, which is the gap M1 exists to close.
- Observation (2026-10-10): `scripts/publish-local-minio-images.sh` cannot push to cp3. It uses
  `docker push`, and cp3's Docker daemon does not list `k3d-registry.localhost:5000` as an
  insecure registry ("server gave HTTP response to HTTPS client"). The cp3 bring-up copied the
  same MinIO images in by digest with skopeo and bound them with the overrides, so the default
  binding was not exercised there.
- Observation (2026-10-10): re-seeding a fresh registry from an export must leave out
  platform-owned images. The exported `net-certmanager-controller` image carries the retired
  history's ownership stamp, and the bootstrap refused it (`unverified-owner`). The k3d registry
  refuses deletes, so the fresh context was discarded and rebuilt without that image.


## Decision Log

- Decision: A volume's backup members share its claim's scope and logical key. Their roles extend
  the claim's role (`<role>-backup`, `-backup-account`, `-backup-read-role`,
  `-backup-read-binding`, `-backup-signing-key`), so service and worker volumes of the same name
  never collide.
  A volume receipt's source is exactly `{pvcUid}`. `ScheduledReceiptExpectation`'s StatefulSet UID
  becomes optional, so a database-shaped expectation never accepts a volume receipt.
  Schedule names over the CronJob's 52-character limit keep a readable prefix plus a
  20-character digest.
  Rationale: this reuses the database producer's upload, signing and grading unchanged. Database
  CronJob bytes are unchanged.
  Date: 2026-10-10

- Decision: Bind the retention policy in the release code, as decision D6 bound the objective
  presets, not in the signed schedule metadata. Admission evaluates it against the widest
  objective's breach window.
  Rationale: no accepted CronJob changes bytes, and no environment value can select a policy. A
  second preset would go into the signed metadata only if it ever differs (ADR 28 amendment).
  Date: 2026-10-10
- Decision: GCS prune deletes pin the reviewed generation and prove absence only by the JSON API's
  404. One idempotent recovery Job handles any stopped prune on both backends, archive first.
  Rationale: a failed request must never read as "absent", and a receipt must never go while its
  archive is live.
  Date: 2026-10-10
- Decision: Batch ingestion is one review of per-run scopes, each compiled by the existing
  single-run compiler. Verification, acceptance and restore authority are unchanged.
  Rationale: the operator approved this form on 2026-10-10 (ADR 22 amendment).
  Date: 2026-10-10
- Decision: A prune tolerates un-ingested runs strictly newer than every accepted unpruned run.
  It reports them as not yet ingested, never as candidates. The rule is checked at planning and
  at the apply-time provider check.
  Rationale: with uploads every 15 minutes, an exact-listing rule could never be met in practice,
  and keeping newer points only adds safety.
  Date: 2026-10-10
- Decision: Bound scope and Job growth with lagged steps carried by each later prune review. The
  next review retires the prune and receipt scopes of runs whose prune converged. Collection then
  takes two more reviews: the prune and recovery Jobs first, then the ingestion Job, because
  collection refuses a Job that a retained resource still depends on. Prunes closed after a
  failure stay for recovery.
  Rationale: only existing retire and collect semantics can be used. Pruned runs are not
  restorable, so restore authority is unchanged. At steady state about 222 retained runs keep
  their Jobs.
  Date: 2026-10-10

- Decision: The rebuild has its own input and commands (`inventory rebuild-decisions`, `inventory
  rebuild`) instead of an `inventory adopt` field. Its candidate is the accepted scopes with their
  stored native bytes. The lineage is recorded in the journal, not the head: a `rebuilds` field in
  the review, found from the first event that returned the recorded UID.
  Rationale: adopt needs a compiled candidate, and a rebuild after VM loss has none. The head
  format is unchanged, so EP-172 needs a row only for the review field.
  Date: 2026-10-10
- Decision: Data comes back through reviewed restore steps (`db restore-rebuilt`, `storage
  restore-rebuilt`). Each checks its recovery point (an escrowed-key receipt, or for volumes the
  inventory's snapshot record), pins exact object versions, and loads only into an empty target
  as atomically as the engine allows:
  - PostgreSQL in one transaction;
  - ClickHouse through a staging database and a single `RENAME TABLE`;
  - Redis through an atomic file rename and a restart without saving, checked against the RDB's
    key count;
  - volumes through a staging directory renamed into place.

  `VolumeRecoverySource` is the seam M3's scheduled volume receipts fill.
  Rationale: a fenced restore inside the rebuild transaction would need a new executor operation
  per engine. An empty-target check plus an atomic load makes a retry safe, and nothing writes
  before the apps deploy.
  Date: 2026-10-10

- Decision: Put the certificate wait in the Kubernetes readiness adapter, not in the application
  deploy through `Nagare.Domain.Tls`. The adapter gains `domainMappingReady` plus a wait for an
  https `status.url` after an HTTP downgrade. `Nagare.Domain.Tls` stays test-only.
  Rationale: the adapter is the single readiness authority for every inventory apply, resume and
  health probe, and the recovery model drives it through the world (ADR 25). A context with TLS
  off (`TLSNotEnabled`) stays ready, so HTTP-first contexts are unaffected.
  Date: 2026-10-10
- Decision: route-check uses curl with an explicit trust anchor, and first checks that a wrong
  embedded CA is refused. In local mode it connects through a Kourier port-forward with
  `--connect-to`, so the certificate is still verified for the real host.
  Rationale: a stage that could skip verification would prove nothing; the v0.4.0 drivers used
  `curl -k`. The loopback domain's port 443 can belong to a host proxy.
  Date: 2026-10-10
- Decision: Fix the dead MinIO image default in M1 instead of deferring it.
  Rationale: the operator chose this on 2026-10-10. Every fresh local context, including N1, needs
  it.
  Date: 2026-10-10

- Decision: M2's targets are the proposed defaults, confirmed by the operator on 2026-10-09: keep
  every scheduled recovery point for 48 hours and the newest point of each day for 30 days, always
  keep the newest verified point, and a 4-hour recovery-time objective. They are recorded in UC-3
  (`docs/use-cases/003-operate-nagare-as-a-team-run-intranet-paas.md`) and
  [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md).
  Rationale: the operator chose "Accept defaults" when EP-162's questions were asked.
  Date: 2026-10-10

- Decision: One ExecPlan under MasterPlan 24 covers D2, D3, D4 and the service rebuild. Team
  operation and the release transition are excluded.
  Rationale: the operator asked on 2026-10-09 for one plan to close the gaps between v0.4.0 and
  intranet use. MasterPlan 24 is the intranet initiative and carries its intention. Team operation
  waits on EP-162 and EP-163 there. EP-172 already owns moving an installation to the next release.
  Date: 2026-10-09

- Decision: Nothing runs in the background to delete old backups. Retention is a target that
  `server status` grades, plus a reviewed prune the operator runs.
  Rationale: operator decision D1 (MasterPlan 23, 2026-10-03) rejected a daemon or second writer
  to the single-writer inventory store. A grade plus a reviewed exit keeps that rule while making
  the target visible.
  Date: 2026-10-09

- Decision (accepted by the operator 2026-10-09, conditional on staying small; see the M3 slice
  checkpoint): back up volumes by extending the existing scheduled database producer rather than
  adopting K8up. The pattern is a CronJob,
  receipts signed with HMAC (v5), escrowed signing keys and `Nagare.Inventory.BackupFreshness`
  grading. The volume archive is the tarball format `nagarectl storage snapshot` already writes.
  Rationale:
  - Everything except the producer is already proven natively for databases on v0.4.0: grading,
    escrow, receipt verification, refusal of corrupt uploads, and restore to a new PVC.
  - K8up would add a second repository format and a second retention engine beneath the journal,
    which EP-163 lists as an open question (`docs/plans/163-…md`, K8up questions).
  - MasterPlan 24's Decision Log said to evaluate before implementing. The operator recorded this
    choice there on 2026-10-09.
  Date: 2026-10-09

- Decision: The rebuild restores into a new incarnation through an explicit lineage decision. It
  does not relax ADR 27.
  Rationale: under ADR 27, a backup restores only into the physical incarnation it was taken from,
  and planning refuses a missing durable member (`durable-resource-missing`,
  `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs:766`). A reviewed decision that names the
  predecessor incarnation and the exact verified recovery point keeps every restore traceable. A
  tolerance in the identity check would let a backup reach an object nobody reviewed.
  Date: 2026-10-09

- Decision: A volume run's ingestion is the database ingestion with the StatefulSet pin made
  optional. Its Job declares `nagare.dev/scheduled-receipt-source-kind: volume`, so the executor
  requires exactly three pins and refuses a StatefulSet pin.
  Rationale: verification, acceptance and restore authority stay identical, and database Job bytes
  are unchanged.
  Date: 2026-10-10

- Decision: A scheduled volume run is a rebuild recovery point (`scheduled-volume`) verified
  against its ingestion record, not its HMAC.
  Rationale: ingestion already verified the HMAC and pinned exact versions; this keeps the rebuild
  independent of key escrow.
  Date: 2026-10-10

- Decision: Retention ranks a scheduled run only against runs of the same schedule
  (`scheduled.backup.schedule`) and source scope.
  Rationale: per-volume retention in one application scope; splitting siblings never prunes a
  point the union would keep.
  Date: 2026-10-10

- Decision: A volume prune is current when the run's claim incarnation and schedule revision are
  current, not the application scope's revision.
  Rationale: app deploys must not block pruning.
  Date: 2026-10-10

- Decision: A scratch restore of a scheduled run carries no backup-Job pin; the run's ingestion
  record authorizes it, as for a rebuild restore.
  Rationale: ingestion Jobs may be collected; pinned versions and digests carry the trust.
  Date: 2026-10-10

- Decision: A prune records a policy pin by source kind. A database pins its scope revision; a
  volume pins its claim's recorded incarnation and its schedule's accepted spec, bound to the run's
  own claim and schedule.
  Rationale: the pin must survive changes that do not alter the retention source, or a stopped
  prune loses its exit.
  Date: 2026-10-10

- Decision: A prune recovery is reviewable while the failed prune scope is accepted as its review
  desired and the run's receipt scope as that review saw it; other scopes may move.
  Rationale: the close of the failed prune itself moves the head; the pin decides whether the
  policy still holds.
  Date: 2026-10-10

- Decision: Defer key-kind-aware escrow and standalone services' and workers' volumes to the next
  release (overnight deferral, to be reported to the operator).
  Rationale: ingested runs need no escrow, and neither is in M3's acceptance.
  Date: 2026-10-10

- Decision: The enforcer polls its mounted backend map every five seconds and serves each request
  with the map in force; a map that does not decode is logged and the previous routes keep
  serving. A deploy does not roll the enforcer.
  Rationale: the kubelet swaps a mounted ConfigMap in place, so reading the file is the standard
  way to consume it. Rolling the enforcer from an application deploy would make an application
  scope change a platform scope's workload.
  Date: 2026-10-10

- Decision: route-check waits up to 180 seconds for a new route's 502 to clear and fails at once
  on any other status.
  Rationale: the kubelet's ConfigMap sync (about a minute) plus the five-second re-read bound
  how long a just-deployed route can be unknown to the enforcer.
  Date: 2026-10-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Nagare is a small platform-as-a-service. One Google Compute Engine VM runs NixOS and k3s, a
lightweight Kubernetes, and applications run as Knative Services. The operator drives it with the
Haskell command-line tool `nagarectl`, whose source is under `cli/nagarectl/`. Release and test
tooling lives in `cli/nagare-harness/`, and recipes are in `justfile`.

A *context* names one installation: a GCP project or, in local mode, a k3d cluster on the
workstation. Contexts are described in `docs/user/contexts.md`. Since MasterPlan 23, every change
to a context goes through the *typed scoped inventory* (ADR 22):

- The operator saves a reviewed plan with `--save-plan DIR`.
- `nagarectl inventory apply DIR --yes` executes it.
- Every step is written to a journal in the context's inventory store.

A *durable* member is one that holds data, such as a database StatefulSet or a PVC. Each durable
member records the Kubernetes UID of the object it created. That UID is its *physical incarnation*
(ADR 27).

Three engineering rules apply to all work here:

- ADR 25 (`docs/adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md`):
  defects are found by the effect interpreters and the recovery model under
  `cli/nagarectl/test/`. Native runs only confirm. Every native run is listed in M5 in advance, and
  a defect it finds gets a class-level interpreter regression before the run is repeated once.
- ADR 26 (`docs/adr/0026-stopped-transactions-close-by-per-operation-proof.md`): a transaction
  stopped at any operation must close by proving what that operation did.
- Follow `docs/runbooks/before-a-native-run.md` before any native run.

The rest of this section covers each gap in turn.

**HTTPS and login (D3).** Most of the pieces exist; nothing has proven them end to end.

*How TLS is set up today:*
- In cloud mode, the ClusterIssuer `letsencrypt-dns` (`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl`)
  obtains certificates from Let's Encrypt with a DNS-01 challenge against Cloud DNS. The ACME
  account belongs to the context (ADR 10).
- In local mode, `just local-bootstrap` installs a private CA, `nagare-local-ca`
  (`cluster/bootstrap/local-tls/clusterissuer.yaml`), and turns on Knative external-domain TLS.
- `cli/nagarectl/src/Nagare/Inventory/Components/Upstream.hs` (around lines 202–217 and 296–370)
  chooses the issuer and merges `cluster/bootstrap/knative-serving/config-network-tls.yaml`. That
  file enables TLS for namespaces labelled `nagare.dev/app-namespace=true`.
- Cloud TLS is the context setting `NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED=1`. On a context with
  inventory history, it changes only through `nagarectl context create NAME --force
  --enable-external-tls --save-plan DIR` followed by `nagarectl context apply DIR --yes`
  (`cli/nagarectl/src/Nagare/Context/Review.hs` lists it as an allowed operational change). After
  that, `just cluster-enable-tls` (`justfile` around line 201) runs the reviewed bootstrap.
- The recipe comment and `cluster/bootstrap/cert-manager/README.md` still show the direct
  `context create --force` form, which is refused once a context has history.
- Each route's TLS mode is typed in the DSL as `DomainTls` (`AutomaticTls | SuppliedTlsSecret`,
  `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`).
- `cli/nagarectl/src/Nagare/Inventory/Application/Service.hs` (around lines 574–614) requires
  protected routes to use automatic TLS.
- `cli/nagarectl/src/Nagare/Domain/Tls.hs` contains a fail-closed wait for a route's certificate.
  Only tests call it, so whether the inventory deploy waits for certificate readiness is unproven.
- The design is ADR 20 (`docs/adr/0020-domain-routing-and-tls-ownership-are-explicit.md`). Hostnames
  are claimed explicitly, origin TLS is automatic through Knative and cert-manager, and DNS,
  routing and TLS readiness are separate signals.

*How login works today:*
- Protected login is *forward auth*: before a request reaches the app, the ingress asks an
  enforcer whether to admit it. The enforcer is `nagare-access` (`cluster/bootstrap/nagare-access/`).
  It sends anonymous users to the shomei login portal (`cluster/bootstrap/shomei/`) and asks the en
  authorization service (`cluster/bootstrap/en/`) whether a signed-in user has a grant.
- An app opts in with `access = Just requireLogin` in its `nagare/Config.hs`
  (`cli/nagare-dsl/src/Nagare/Dsl/Access.hs`).
- Grants are reviewed inventory scopes (`nagarectl access …`, `docs/user/access.md`).
- Password login over local HTTPS was shown in EP-85. The WebAuthn passkey ceremony has never been
  completed in a browser that trusts the certificate (EP-85 M4b, EP-117 M6).
- The release fixture already uses `requireLogin`:
  - `fixtures/inventory-release/local/apps/scenario-a/nagare/Config.hs`;
  - route `scenario-a.127-0-0-1.sslip.io` in `fixtures/inventory-release/local/scenario.json`.
- Neither acceptance run ever requested the route. The archived v0.4.0 drivers only list grants
  (`docs/audits/mp23-independent-results-2026-10-07/drivers-83124396/c2/phase3-misc.sh`). The one
  HTTPS request in the drivers used `curl -k`, which skips certificate verification
  (`drivers-83124396/c3/s4-drill.sh`).
- EP-168 (`docs/plans/168-script-the-local-acceptance-run-as-one-command.md`, MasterPlan 26) is
  porting those drivers into `nagare-harness local-acceptance`. M1's route stage belongs there.
- Two user docs are stale:
  - `docs/user/local-development.md` (around lines 33–35) says local mode serves plain HTTP.
  - `docs/user/cluster-bootstrap.md` (around lines 224–226) says local TLS is tracked separately.

**Retention (D4, first half).**
- Scheduled database backups come from a CronJob, `nagare-dbbackup-<db>`, rendered by
  `cli/nagarectl/src/Nagare/Database/Backup.hs`. Each upload writes a receipt signed with
  HMAC-SHA256.
- `cli/nagarectl/src/Nagare/Inventory/BackupFreshness.hs` grades the newest verified recovery point
  against the context's objective, `NAGARE_BACKUP_RECOVERY_POINT`:
  - `hourly` runs every 15 minutes, warns at 30 minutes and breaches at one hour;
  - `daily` warns at 25 hours and breaches at 26 hours.
- `nagarectl server status` shows one "recovery point" row per database
  (`cli/nagarectl/app/Nagare/Cli/Data/ScheduledReceipts.hs`, `cli/nagarectl/src/Nagare/Ops/Probe.hs`).
- Receipts already carry a `keep` value (`keep` field, `Backup.hs:196`), but nothing enforces it:
  - the receipt listing prints "keep and expiry are unenforced";
  - `nagarectl db prune-scheduled-backups` exits with "new scheduled pruning is deferred"
    (`cli/nagarectl/app/Nagare/Cli/Commands/Database.hs`, around lines 209–211);
  - admission refuses it as `deferred-operation`
    (`cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs`, around lines 161–168 and 281).
- Recovery of an already-admitted partial prune exists as `db recover-scheduled-prune`
  (`cli/nagarectl/app/Nagare/Cli/Data/ScheduledPrune.hs`). M2 builds on that.
- Manual backups have reviewed, expiry-gated pruning (`db prune-backup`, `storage prune-snapshot`).
- `snapshotsToPrune` in `cli/nagarectl/src/Nagare/Storage/Snapshot.hs` is a keep-last-N function
  that nothing calls.
- Operator decision D6 (MasterPlan 23) fixed the two objective presets. Arbitrary durations and
  per-database overrides were rejected.

**Volumes (D2).**
- `nagarectl storage snapshot APP VOLUME --snapshot-id ID --save-plan DIR`
  (`cli/nagarectl/src/Nagare/Storage/Snapshot.hs`) mounts the PVC read-only and uploads a tar.gz
  to `gs://<bucket>/manual-volumes/<ns>/<app>/<volume>/<id>.tar.gz` (MinIO in local mode).
- Its receipt holds only a SHA-256; it has no HMAC.
- `storage restore` restores into a new PVC; restoring into the live volume (`--into-live`) is
  refused.
- No scheduler exists. The only volume line in `server status` is a legacy probe of the `volumes/`
  prefix (`backupPrefixes`, `cli/nagarectl/src/Nagare/Ops/Probe.hs:267`), which never sees
  `manual-volumes/` and printed `UNKNOWN backup volumes` in the v0.4.0 drills.
- The user guide is `docs/user/backups-and-disaster-recovery.md`, sections "App volumes" and
  "Managed databases".

**Rebuild (D4, second half).**
- `docs/user/backups-and-disaster-recovery.md` ("Total cluster loss: recover the data", "Rebuilding
  the host") and `docs/runbooks/disaster-recovery.md` both state the limit: data recovery is proven
  (20 s into a scratch engine in the v0.4.0 drill), but the same context cannot be brought back into
  service.
- After a rebuild, planning refuses an accepted durable member whose object is gone
  (`durable-resource-missing`, `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs` around lines
  766 and 800).
- A *rebind* (`docs/runbooks/inventory-operations.md`, "Replaced and unrecorded members") adopts a
  live object as the incarnation. It also supersedes the old incarnation's recovery points, so a
  rebind cannot restore data.
- Live restore modules already exist: `cli/nagarectl/src/Nagare/Inventory/LiveRestore*.hs` and
  `cli/nagarectl/src/Nagare/Inventory/DataFence.hs`. A data fence blocks writes to a member while
  its data is being replaced.
- No MasterPlan owns rebuild in place. MasterPlan 21 excludes it explicitly.

**ADRs consulted:**
- ADR 6: an admitted context cannot change platform version except through EP-172's transition.
- ADR 10: ACME identity.
- ADR 15: authentication and forward auth.
- ADR 20: routing and TLS.
- ADR 22: the inventory.
- ADRs 25, 26 and 27.

No cross-repository ADR applies.


## Plan of Work

The milestones are ordered by value to the intranet and by how little each depends on others. M1
can start immediately. M2 needs the operator's targets. M3 has its decision and starts with a slice
checkpoint. M4 depends
only on the recovery model. M5 is the only place native runs happen.

**Milestone 1: HTTPS and login are checked, not assumed.** Do these in order:

1. Settle whether the inventory deploy waits for the route's certificate. Write an
   effect-interpreter test in `cli/nagarectl/test/`: a fake Kubernetes world in which the route's
   Knative `Certificate` stays `Ready=False`.
   - If deploy reports success anyway, wire `Nagare.Domain.Tls`'s wait into the application deploy
     path (`cli/nagarectl/src/Nagare/Inventory/Application/Service.hs` and its readiness adapter
     `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesReadiness.hs`) so deploy fails closed.
     The test must fail on the current source.
   - If deploy already waits, keep the test as a regression and delete the unused module if
     nothing else needs it.
2. Add a route check to the harness: a new module `cli/nagare-harness/src/Nagare/Harness/RouteCheck.hs`
   that EP-168's `local-acceptance` runs as a stage after the fixture deploy. It reads the CA
   certificate:
   - in local mode, from Secret `cert-manager/nagare-local-ca`;
   - in cloud mode, from the system trust store, so it never skips verification.
3. The route check asserts three things against the fixture's `requireLogin` route, in order:
   1. An anonymous `GET` returns 302 whose `Location` is the shomei portal.
   2. A login with the fixture's test user and its password, run as the HTTP form exchange the
      portal serves (see `docs/user/auth-portal.md`), produces a session cookie, and `GET` with that
      cookie returns 200 with the fixture's body.
   3. After a reviewed `access revoke` of that user's grant, the same cookie gets 403 within the
      enforcer's 30-second decision cache (`cluster/bootstrap/nagare-access/service.yaml`).
4. Give the stage a negative self-test: pointed at a context with TLS disabled, or at a
   deliberately wrong CA, it must fail with a named reason.
5. Make a fresh local bootstrap pull MinIO images that exist. Publish them with
   `scripts/publish-local-minio-images.sh`, which builds them from digest-checked upstream release
   binaries, and bind them by default. Refuse the dead `quay.io/minio/*` default with a message
   that names the script.
6. Fix the stale docs:
   - the recipe comment at `just cluster-enable-tls` and `cluster/bootstrap/cert-manager/README.md`
     should show the reviewed `--save-plan` form;
   - the two local-mode statements should be removed.

At the end, a local acceptance run fails if HTTPS or login breaks. If EP-168 has not landed
`local-acceptance` when M1 is done, run the stage standalone as `nagare-harness route-check
--context NAME` and register it with EP-168 through that plan's stage list. Do not build a second
driver.

**Milestone 2: retention is a graded target with a reviewed exit.**

*Targets.* The operator's targets come from EP-162 M1, which asks for recovery objectives; this
plan adds retention to its questions. If EP-162 M1 is not done when M2 starts, propose these
defaults and record the operator's yes or changes in this plan's Decision Log:
- Keep every scheduled recovery point for 48 hours.
- Keep the newest point of each day for 30 days.
- Always keep the newest verified point.
- Recovery-time objective: 4 hours, from the start of the rebuild to the service answering.

*Implementation.*
1. Implement the rule as a pure function next to `BackupFreshness`, with unit tests: a new module
   `cli/nagarectl/src/Nagare/Inventory/BackupRetention.hs`. It takes verified receipts and the
   policy and returns the receipts to keep and the receipts past retention.
2. Bind the policy to the signed schedule metadata in the same way decision D6 bound the objective:
   reuse the `keep` field the receipt already carries, or extend it. Retention must not come from
   an editable environment value.
3. `server status` adds one line per database: "retention: N past policy". It is WARN when N > 0.
4. Lift the deferral of `db prune-scheduled-backups`. It saves a review naming exactly the receipts
   past policy. Admission re-reads each receipt and object and refuses if the newest verified
   recovery point, or a point inside the objective window, would be removed.
5. Before writing executor code, add recovery-model scenarios to
   `cli/nagarectl/test/InventoryRecoveryModelSpec.hs` and its world (`cli/nagarectl/test/Nagare/Test/Model/`):
   - a prune stopped after each operation closes through the existing `db recover-scheduled-prune`
     by per-operation proof (ADR 26);
   - a mutation that lets the prune pick the newest point must be caught.
6. Apply the same keep-last rule to volume receipts once M3 exists.

**Milestone 3: volumes inside the recovery-point objective.**

*Decision.* On 2026-10-09 the operator chose to extend the database producer, on condition that
it does not become a long project. The scheduled Job in `cli/nagarectl/src/Nagare/Database/Backup.hs`
already has two parts:
- a dump container that writes `/dump/backup.<ext>` and is engine-specific (`dumpShell`,
  `dumpEnv`);
- an upload container that compresses, uploads create-only, reads back and signs the receipt, and
  is independent of the engine except for the file extension.

A volume source is therefore a new dump container (a `tar` of the PVC mounted read-only) plus a
source kind that replaces `Engine` wherever the extension and receipt are chosen. The receipt
parser in `cli/nagarectl/src/Nagare/Inventory/BackupReceipt.hs` currently keys on the engine name.

*Slice checkpoint (do this first; it decides whether M3 stays small).* Build one vertical slice
before anything else:
- one backup-included fixture volume gets its CronJob through the application's reviewed deploy;
- on a local context, it uploads a tarball with a signed v5 receipt;
- `server status` shows its graded recovery-point row.

The slice passes when it needed only:
- the new dump container;
- the source kind in the job inputs and receipt;
- a PVC-only source-identity check beside the database's StatefulSet/PVC check (in
  `cli/nagarectl/src/Nagare/Inventory/ScheduledIngest.hs`);
- the status row.

If it needs a new ingestion or acceptance semantics, or a change to how receipts become restore
authority, stop and report to the operator with what was found. Do not push on. Record the
result in Surprises & Discoveries either way.

*After the slice:*
1. Generalise the scheduled producer in `cli/nagarectl/src/Nagare/Database/Backup.hs` so that a
   backup-included volume (`docs/user/backups-and-disaster-recovery.md`, "App volumes") gets a
   CronJob, `nagare-volbackup-<app>-<volume>`. The CronJob:
   - mounts the PVC read-only, as `storage snapshot` does;
   - writes the tarball under a new `scheduled-volumes/` prefix;
   - writes a v5 HMAC receipt with its own escrowed signing key (`db escrow-signing-key` becomes
     key-kind aware, or gains a `storage` twin).
2. Extend `scheduledRecoveryPointProbes` (`cli/nagarectl/app/Nagare/Cli/Data/ScheduledReceipts.hs`)
   to return volume rows graded by `BackupFreshness` against the same context objective.
3. Delete the legacy `backup volumes` probe (`backupPrefixes` in `cli/nagarectl/src/Nagare/Ops/Probe.hs`). It grades
   a prefix nothing writes.
4. Restore of a scheduled volume receipt reuses `storage restore` into a new PVC. Add the receipt
   kind to `cli/nagarectl/src/Nagare/Inventory/VolumeRestoreSource.hs`.
5. Recovery-model scenarios cover the CronJob's creation and update as reviewed scope changes,
   exactly as for databases.

*Consistency limit.* A tarball of a volume an app is writing is consistent per file, not per
volume. Document that an app needing transactional consistency belongs in a managed database. This
is the same contract the manual snapshot has today.

*If the slice checkpoint stops,* the alternatives are K8up (EP-163) or keeping volumes outside the
objective; the operator chooses. The acceptance below stays as written.

**Milestone 4: rebuild the service after losing the VM.**

1. Add a reviewed lineage decision to the inventory. It is an input to `nagarectl inventory
   adopt`, like the rebind input in `docs/runbooks/inventory-operations.md`, and names:
   - one durable member whose accepted object is confirmed absent;
   - the predecessor incarnation's UID;
   - one verified recovery point of that incarnation: a scheduled receipt verified with the
     escrowed key, or a manual backup receipt.
2. With the decision present, planning replaces the `durable-resource-missing` refusal with this
   sequence:
   1. create the member (a new incarnation);
   2. fence its writes with the existing data fence;
   3. restore the named recovery point;
   4. verify the restored content against the receipt;
   5. lift the fence.

   The journal records the new incarnation with `restoredFrom = {incarnation, recoveryPoint}`. The
   predecessor's later recovery points remain listed but are never restorable into the new
   incarnation without another decision.
3. Write the ADR 27 amendment in the same change.
4. Model first. Add the decision to the recovery model's operation set (EP-177's resource-kind
   table, `docs/plans/177-generate-recovery-model-coverage-from-a-resource-kind-table.md`, if
   landed). Add scenarios that stop after every step and prove each closes by per-operation proof.
   A test must show that a restore into an incarnation not named by the decision is refused.
5. Write the runbook section "Rebuild the service after losing the VM" in
   `docs/runbooks/disaster-recovery.md`. It joins "Rebuilding the host"
   (`docs/user/backups-and-disaster-recovery.md`) with a rebuild that:
   1. runs the reviewed bootstrap;
   2. generates one lineage decision per durable member from the newest verified recovery points:
      `nagarectl inventory rebuild-decisions --out FILE`, a read-only command that prints the input;
   3. adopts it, then applies the applications.
6. Rehearse the runbook locally with `k3d cluster delete` standing in for VM loss, and time it.
   Native timing on a real VM belongs to M5.

**Milestone 5: two listed native runs, then the release.**
1. Complete `docs/runbooks/before-a-native-run.md`, then run:
   - **N1** on cp3: a fresh local context through `nagare-harness local-acceptance`, with M1's route
     stage, M2's prune review, M3's volume freshness and restore, and M4's cluster-delete rebuild.
   - **N2** on a fresh cloud context with `--enable-external-tls`:
     - the wildcard certificate becomes Ready;
     - the route stage passes with system trust;
     - the operator completes one passkey login in Chrome, recorded with a screenshot and the
       portal's audit line;
     - `server status` shows database and volume freshness healthy;
     - the VM is deleted, and the rebuild runbook restores service with the fixture's data. The
       elapsed time is recorded against the agreed recovery-time objective.
2. Treat N2 as one bounded cloud sequence and ask the operator for its go-ahead once.
3. Archive the drivers and evidence under
   `docs/audits/intranet-gaps-<date>/drivers-<commit>/`, as was done for
   `docs/audits/mp23-independent-results-2026-10-07/drivers-83124396/`.
4. Add a compatibility row to EP-172's table for every journal or receipt format this plan
   changed, or a reviewed migration step with its own model scenario. Without one, the release
   must not ship the change.
5. In the next release's notes, move D2, D3 and D4 from "Unmet production targets" to the changes
   list, citing the N1 and N2 evidence.


## Concrete Steps

Work from the repository root, `/Users/shinzui/Keikaku/bokuno/nagare`, on `master`; there are no
feature branches. Stage files by explicit path, never with `git add -A`.

Every Haskell commit:

```bash
just haskell-style-check
just gate-fast
```

Each push batch:

```bash
just gate
just land <rev>
```

`just land` verifies the gate record and pushes.

For M1, after the interpreter test and route stage exist, bring up a local context and run the
stage:

```bash
nagarectl context use <local-context>
just local-up
just local-bootstrap
nagare-harness route-check --context <local-context>
```

Expected output on success (shape; exact wording is the implementer's):

```text
route https://scenario-a.127-0-0-1.sslip.io/ anonymous: 302 -> https://auth.127-0-0-1.sslip.io/… ok
route login as fixture-user: 200 ok
route after revoke: 403 ok
```

To check that the stage fails closed, run it against the wrong CA:

```bash
nagare-harness route-check --context <local-context> --ca /dev/null
```

Expected: a non-zero exit naming a certificate verification failure.

For M2 and M3, the operator-visible checks are:

```bash
nagarectl --context <ctx> server status
nagarectl --context <ctx> db prune-scheduled-backups <db> --save-plan /tmp/prune-review
nagarectl --context <ctx> inventory apply /tmp/prune-review --yes
```

Before M3, `server status` shows a WARN retention line. After M3, it shows `recovery point` rows
for each backup-included volume, graded `healthy; age=…; objective=hourly`.

For M4, the local rehearsal is:

```bash
k3d cluster delete nagare-local
just local-up
just local-bootstrap
nagarectl --context <local-context> inventory rebuild-decisions --out /tmp/lineage.json
nagarectl --context <local-context> inventory adopt --input /tmp/lineage.json --out /tmp/lineage-review
nagarectl --context <local-context> inventory apply /tmp/lineage-review --yes
```

Then deploy the fixture apps through their saved plans, read back the seeded rows and volume file,
and record the elapsed time.


## Validation and Acceptance

**M1** is accepted when all of these hold:
- The new interpreter test fails on the source before the fix (or is shown to pass because the wait
  already exists, with the evidence recorded).
- `nagare-harness route-check` passes on a fresh local context and fails against a wrong CA.
- The full gate is green.

**M2** is accepted when all of these hold:
- The retention function's unit tests pass.
- The new recovery-model scenarios pass, and their mutation (letting the prune choose the newest
  point) is killed. Record it in `cli/nagarectl/test/mutations/` with its exact `records.json`
  pattern, following the existing records.
- On a local context with backups older than policy, `server status` shows WARN, and the reviewed
  prune removes exactly the listed objects.

**M3** is accepted when all of these hold:
- On a local context, a backup-included volume shows a graded recovery-point row within one
  schedule period.
- Deleting the CronJob's newest upload in MinIO makes the row degrade.
- A restore of the newest receipt into a new PVC yields byte-identical files.

**M4** is accepted when all of these hold:
- The model scenarios and the wrong-incarnation refusal test pass.
- The local rebuild rehearsal brings the fixture back with all seeded database rows and volume
  files equal to their pre-deletion values.
- An unchanged replan afterwards has zero operations.

**M5** is accepted when N1 and N2 pass with archived evidence. N2's elapsed rebuild time must be
within the agreed recovery-time objective. If it is not, record the measured time, and have the
operator either accept a revised target or open a follow-up. Do not tick the box against a missed
target.


## Idempotence and Recovery

M1–M4 are code and local runs. A local context can be recreated at will: `k3d cluster delete
nagare-local` (`just local-down` is refused once the context has inventory history), then `just
local-up` and `just local-bootstrap`.

Reviewed applies are journaled. A run stopped mid-way resumes with `nagarectl inventory resume`, or
closes by the reviewed exits ADR 26 requires; never by editing the store.

The N2 cloud context is disposable and is retired when evidence is archived, by the same
exact-name disposal used for the MasterPlan 23 contexts
(`docs/audits/mp23-independent-results-2026-10-07/drivers-83124396/disposal/`).

When any guard refuses during N1 or N2, stop and report; do not work around it.


## Interfaces and Dependencies

This plan adds the following interfaces:

- `Nagare.Harness.RouteCheck`, in `cli/nagare-harness`: one stage, given a context, a CA source and
  the fixture's route and user, that returns pass or a named failure. EP-168 consumes it.
- `Nagare.Inventory.BackupRetention`, in `cli/nagarectl`: a pure policy over verified receipts. It
  is shared by database and volume receipts and by `server status`.
- Volume rows in `scheduledRecoveryPointProbes`, graded by the existing
  `Nagare.Inventory.BackupFreshness.backupFreshness`.
- A lineage decision in the inventory adopt input. Its JSON shape is fixed in M4 and documented in
  `docs/runbooks/inventory-operations.md`. It is recorded in the journal as `restoredFrom`.
- `nagarectl inventory rebuild-decisions --out FILE`: read-only, prints lineage decisions for every
  durable member confirmed absent.

Format changes EP-172's compatibility table must carry. EP-172 has not built the table yet, so
the rows are kept here until it does:

| Change | Milestone | An older binary | Migration |
|---|---|---|---|
| The review document gains an optional `rebuilds` field. Each entry has an optional `predecessor` and either `recoveryPoint{kind: scheduled, manual or volume-snapshot; receipt; receiptDigest}` or `fresh: true`. | M4 | refuses to read a review that has the field | none; old reviews read unchanged |
| New standalone scope `database-rebuild-<ns>-<db>-<id>`, with `restore.*` and `restore.rebuild.*` keys. | M4 | does not know the scope kind | none |
| New standalone scope `volume-rebuild-<ns>-<app>-<vol>-<id>`, with `volume-restore.*` and `volume-restore.rebuild.*` keys and the Job annotation `nagare.dev/volume-restore-rebuild-review`. | M4 | refuses the Job's pins | none |
| Prune scope key `scheduled.prune.policy.keep` becomes `scheduled.prune.policy.retention`. | M2 | n/a: v0.4.0 admission refused every scheduled prune, so no v0.4.0 context holds one | none |
| The command coverage `deferredRoutes` list loses `DbPruneScheduledBackups`. | M2 | evidence contract only | none |
| The local MinIO manifest (`cluster/local/minio/minio.yaml`) names locally published images, with a new manifest digest. | M1 | local contexts only | unverified for an existing local context; check before EP-172 M3 |
| An application scope gains five members per retained volume: a ServiceAccount, a Role, a RoleBinding, a signing Secret and the CronJob `nagare-volbackup-<app>-<volume>`. The Secret carries the `nagare.dev/volume-backup` label, and the Job carries `nagare.dev/volume-claim`. | M3 | refuses the volume signing template ("lacks database label") | none; adds appear on the next reviewed deploy |
| A new receipt kind: a v5 envelope with `source {pvcUid}`, stored under the `scheduled-volumes/` prefix. | M3 | does not parse it | none |
| Volume ingestion scope `volume-scheduled-receipt-<ns>-<schedule>-<run>` with `scheduled.backup.source.kind=volume` and no StatefulSet keys; Job annotation `nagare.dev/scheduled-receipt-source-kind: volume` with three pins. | M3 | requires four pins and a StatefulSet key, so it refuses the scope | none; database scopes and Jobs unchanged |
| Rebuild review `recoveryPoint.kind: "scheduled-volume"`. | M3 | refuses the unknown kind | none |
| Restore Job annotation `nagare.dev/volume-restore-scheduled-run` (no backup-Job pins); scope keys `volume-restore.backup.kind: scheduled-volume` and `volume-restore.backup.{object,receipt}[.version]`. | M3 | requires backup-Job pins, so refuses | none |
| Volume prune scopes `volume-scheduled-prune-<ns>-<schedule>-<run>` and `volume-scheduled-prune-recovery-…`. | M3 | refuses them (ranks by source scope only; expects `databases/`) | none; database scopes unchanged |
| Admission and provider evidence key a run's siblings by `scheduled.backup.schedule`. | M3 | ranks by source scope only | none; every accepted run records its schedule |
| Volume prune scopes record `scheduled.prune.policy.{claim,claim.uid,schedule,schedule.spec}` and no `scheduled.prune.policy.revision`. | M3 | refuses ("incomplete policy pins") | none; only volume prunes, new in this release |
| A prune recovery is reviewable when only its own prune scope and the run's receipt scope are unchanged. | M3 | refuses every recovery after the close | none |

The head and journal formats are unchanged. Database receipts and CronJob bytes are unchanged.

Dependencies on other plans:

- M2's targets come from EP-162 M1
  (`docs/plans/162-define-team-operating-requirements-and-decide-availability-for-the-intranet-paas.md`),
  or from the operator's confirmation of the defaults above.
- M3's tooling decision is recorded (MasterPlan 24, 2026-10-09). It depends on no other plan
  unless its slice checkpoint stops; then EP-163
  (`docs/plans/163-evaluate-established-tooling-against-nagare-s-managed-resource-layers.md`) is
  the fallback.
- M1's stage plugs into EP-168. Native run N1 uses `local-acceptance` once EP-168 lands it.
- M4's model work uses the production adapter registry once EP-173 M3 lands
  (`docs/plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md`). Until then,
  use the model's current registry.
- M5's release reaches an existing v0.4.0 installation only through EP-172. Every format change
  here needs its compatibility row.
- Nothing here needs MasterPlan 24's team-operation streams, and they do not wait for this plan.
