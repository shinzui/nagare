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

Full plan before trimming: [183-close-the-intranet-gaps-left-by-v0-4-0-https-login-volume-backups-retention-and-service-rebuild.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/183-close-the-intranet-gaps-left-by-v0-4-0-https-login-volume-backups-retention-and-service-rebuild.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] M1. On a fresh local inventory context, the acceptance run fails unless the fixture's
  protected route answers over HTTPS with the context's certificate trusted:
  - an anonymous request gets 302 to the login portal;
  - a scripted login with a granted user gets 200;
  - a revoked grant gets 403.

  The deploy waits for the route's certificate to be Ready. The docs no longer call local mode
  HTTP-only or show the refused direct `context create --force` form. (2026-10-17: route-check passed on
  a fresh cp3 context, `33330a50`, after the full gate at `d42913c9`; MinIO default `68108069`.)
  - [x] (2026-10-10) Code: the readiness fix, the `nagare-harness route-check` stage with docs, and
    two mutation records. `just gate-fast` is green, and both records were proven locally with
    their exact patterns.
  - [x] A fresh local bootstrap uses locally published MinIO images by default (Surprises,
    2026-10-10). (2026-10-17: `68108069`, with tests of the default binding; the native drills
    still pass the overrides.)
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
      drivers: [cp3-route-check](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/intranet-gaps-2026-10-10/cp3-route-check).
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
- Observation (2026-10-10, volume producer): the first scheduled volume backup on cp3 failed with
  "tar: command not found". The dump container runs `amazon/aws-cli`, which ships neither tar nor
  gzip, and only the database and restore Jobs installed them first. Every test checked the
  rendered manifest, never which tools its image has. Fixed in b4950a69; e5078cd5 checks every
  aws-cli container of every MinIO data-movement Job, and mutation record
  `EP183-volume-dump-without-store-tools` proves the check.

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

- Decision (operator, 2026-10-10): drop M2's native check of the retention WARN row and the
  prune from this release; check it after the release.
  Rationale: a backup becomes prunable only after 48 hours, no backup worth keeping exists yet,
  and the prune is already proven by the recovery model and mutation records.
  Date: 2026-10-10

- Decision (operator, 2026-10-10): cut the next release from what has landed. The only native
  runs are the ones the release process requires: one local and one cloud run on the candidate,
  the cloud run including a deploy and a passkey sign-in. The cluster-delete rebuild rehearsal is
  dropped from this release.
  Rationale: the requirement is that developers can deploy and sign in, and the operator can
  change and upgrade without losing data; the dropped checks add no evidence for it.
  Date: 2026-10-10

## Outcomes & Retrospective

(To be filled during and after implementation.)

