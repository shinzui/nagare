---
id: 199
slug: prepare-clickhouse-26-8-for-first-production-use
title: "Prepare ClickHouse 26.8 for first production use"
kind: exec-plan
created_at: 2026-10-16T23:14:37Z
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-16T23:14:37Z
---

# Prepare ClickHouse 26.8 for first production use

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision
Log, and Outcomes & Retrospective current as implementation proceeds.

## Purpose / Big Picture


Make ClickHouse 26.8 the version a new Nagare database receives by default, and prove
that it is ready for the operator's upcoming first use. On 2026-10-16 the operator
confirmed that no current cluster uses ClickHouse, but use is imminent. This is a
fresh-deployment readiness change: there is no existing ClickHouse installation or
production data to migrate. Completion means a newly created 26.8 database accepts
authenticated connections, keeps data across a restart, and produces backups that
Nagare can restore. A changed version string alone does not establish readiness.

This plan prepares and validates the platform. Publishing a Nagare release and
deploying the upcoming application remain separate work; neither is required to
invent a migration from an installation that does not exist.

## Progress


- [x] M1: New database declarations, maintained examples, and current test paths use 26.8; explicit version choices remain effective and focused checks pass.
  2026-10-16, `cd921241`. Pass: `nagare-dsl-test` (ClickHouse golden on 26.8),
  `nagarectl-test` 163/163 (new: omitted version renders server and scheduled
  backup on `clickhouse-server:26.8`; explicit `26.8.29.10` survives image and
  annotation; backup and scratch-restore ZIP rendering on 26.8), harness 62/62,
  `just haskell-style-check`. Public `db create clickhouse ep199-ch --size 1Gi --memory 2Gi
  --dry-run` shows server and backup images `clickhouse-server:26.8`, ports 9000/8123,
  `CLICKHOUSE_USER`/`CLICKHOUSE_PASSWORD` Secret refs, `limits.memory: 2Gi`, the
  1610612736/268435456 memory ConfigMap and the `/var/lib/clickhouse` mount.
- [ ] M2: A fresh managed 26.8 instance passes authenticated access, restart persistence, and manual and scheduled backup/scratch-restore checks with recorded evidence.
- [ ] M3: Documentation and the first-use handoff match the verified behavior, required gates pass, and implementation evidence identifies the tested revision and image.

Docs and `scripts/clickhouse-drill.sh` landed in `ae846cc4`. Next: green full gate on the
candidate, then M2 on a fresh disposable local context.

## Surprises & Discoveries


## Decision Log


2026-10-16 — Treat this as preparation for first use, with no 25.8-to-26.8 data
migration, downgrade rehearsal, or cross-version backup conversion. The operator
confirmed there is no current ClickHouse deployment. Validate fresh 26.8 recovery
before accepting first-use readiness. If that deployment assumption changes before
implementation, revise the scope before touching existing ClickHouse data.

2026-10-16 — Use the upstream `clickhouse/clickhouse-server:26.8` release-line tag
as the default, matching Nagare's existing `25.8` policy. Record the resolved server
patch version and image digest in validation evidence because a release-line tag
can advance. Explicit full-version configuration remains available. A new global
image-digest policy or automatic dependency updater is outside this change.

2026-10-16 — Preserve historical plans, immutable release evidence, and released
transition fixtures as records of their original versions. Update maintained
examples and tests that exercise current defaults; retain explicit old-version
fixtures when they prove decoding or caller-selected version behavior.

2026-10-16 — Run M2 in the platform-declared `personal` namespace with the dedicated
database name `ep199-ch`, not a new `ep199-ch` namespace. Reviewed `db create` requires the
platform's accepted Namespace declaration, which a local context has for `personal`; creating
a namespace scope would add work this version change does not need.

2026-10-16 — The disposable context is a fresh local context on Colima profile `nagare-mp23`,
bootstrapped on v0.6.3 and moved to the candidate by `just release-rehearse REV 0.6.3`. That
is the existing unattended route to a context running a packaged candidate; the rehearsal's
own record is not release evidence for this change and is not committed.

## Outcomes & Retrospective


## Context and Orientation


`cli/nagare-dsl/src/Nagare/Dsl/Database.hs` defines `Engine`, the validated image-tag
wrapper `EngineVersion`, and `defaultEngineVersion`. The ClickHouse default is
currently `25.8`. `mkEngineVersion` already accepts `26.8` and full patch tags;
it does not impose a server-version allow-list. `cli/nagarectl/src/Nagare/Database/Create.hs`
uses that default in `buildDatabase` when no version is supplied. The renderers in
`cli/nagare-dsl/src/Nagare/Dsl/Database/Render.hs` produce a StatefulSet (a controller
maintaining the database Pod), Service (stable internal network address), and PVC
(the persistent data-volume claim), plus a ClickHouse memory ConfigMap.

[EP-43](43-managed-database-substrate-spike-and-stateful-rendering-feasibility.md)
recorded the June spike against 25.8.24.21. Its durability and memory results are
historical evidence, not a 26.8 acceptance result. Preserve the existing two exposed
ports, native protocol 9000 and HTTP 8123, credential wiring, and the 1.5 GiB server
memory cap and 256 MiB mark cache unless 26.8 validation demonstrates a necessary
change. Use the example's 2 GiB container memory limit for the fresh deployment.

The maintained example is `cluster/examples/clickhouse-analytics/nagare/Database.hs`,
with instructions in `cluster/examples/clickhouse-analytics/README.md`. The example
application uses `clickhouse-driver` over port 9000. Its Dockerfile currently
installs that client without a version pin; this plan need not redesign Python
dependency management, but any application check must record the client version.
`cli/nagare-harness/src/Nagare/Harness/FixtureSmoke.hs` also has a ClickHouse backing
service in `serviceFor`, currently naming `clickhouse/clickhouse-server:25`.
Correct that maintained path to 26.8; do not propagate the invalid bare-year tag.

Current tests live in `cli/nagare-dsl/test/Spec.hs`, its
`cli/nagare-dsl/test/golden/db-clickhouse.*.yaml` files,
`cli/nagarectl/test/Nagare/Test/Database.hs`,
`cli/nagarectl/test/Nagare/Test/Backup/Rendering.hs`,
`cli/nagarectl/test/Nagare/Test/Backup/Restore.hs`, and
`cli/nagarectl/test/DataFenceSpec.hs`. Review their purpose before replacing 25.8.
`cli/nagarectl/src/Nagare/Database/Backup.hs` and
`cli/nagarectl/src/Nagare/Database/Restore.hs` render the database backup and restore
Jobs. Their client images must follow the declared database version. A scratch
restore writes an isolated destination so the source remains available.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
requires changes to managed resources through saved inventory reviews and guarded
apply. A review is the immutable description of the operations to be applied.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
and [Before a native run](../runbooks/before-a-native-run.md) require relevant
in-memory coverage and a green candidate gate before cluster confirmation. Reuse
existing coverage for unchanged paths; do not build a new recovery model for a
version bump. [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md)
retains the single-node operating model and existing backup/recovery objectives.
This change does not introduce replicated ClickHouse or a new recovery format.
There is no local ADR requiring ClickHouse 25.8.

As checked on 2026-10-16, upstream publishes
[26.8.29.10 LTS](https://github.com/ClickHouse/ClickHouse/releases/tag/v26.8.29.10-lts),
and [its security policy](https://github.com/ClickHouse/ClickHouse/security) supports
26.8 and marks 25.x unsupported. The
[Docker Hub tag record](https://hub.docker.com/v2/repositories/clickhouse/clickhouse-server/tags/26.8)
reports active linux/amd64 and linux/arm64 images. Recheck these sources when
implementing; the observed 26.8 index digest at planning time was
`sha256:6ded2b2c2f2c46f12784bd8000c75f8aa7363372ed64afccaa932456b8cb41e4`.
Mori registry search found no registered upstream ClickHouse server source checkout;
use the official release, image, and documentation sources rather than guessing
server behavior from a client-library checkout.

## Plan of Work


### M1 — Make 26.8 the effective default


Change `defaultEngineVersion ClickHouse` to `26.8`, update the maintained example
and current-version golden outputs, and correct the harness backing-service image.
Keep the existing version-override API. Extend the current create/render tests to
show that omitted version produces a 26.8 StatefulSet and matching backup image,
whereas an explicitly supplied full patch tag survives rendering unchanged. Cover
the 26.8 backup/restore command rendering using existing tests, including the
native database ZIP archive and checksum verification. Keep old-version decoder
and transition fixtures where their purpose is compatibility. M1 is accepted when
the focused suites pass and the public create dry run displays 26.8 with the
existing ports, authentication references, memory configuration, and volume mount.

### M2 — Confirm fresh-instance readiness before use


After the candidate is committed and gated, use a disposable, explicitly selected
Nagare validation context and a dedicated namespace. Follow the native-run runbook;
write the bounded commands into a reproducible script or the existing Haskell
harness before executing them. Prefer an existing disposable local context with
its MinIO object store; this verifies engine behavior without provisioning cloud
infrastructure. Record the context, node architecture, CLI revision, exact server
version, and image digest. A local result is not a claim of cloud GCS validation.

Provision a fresh database through `db create` and `inventory apply`, omitting the
version flag so the deployed result exercises the new default. Use the generated
Secret without printing its password. Confirm authenticated HTTP and native queries
and refusal of an unauthenticated protected query; `/ping` alone is insufficient.
Create `default.ep199_probe` with `ENGINE = MergeTree ORDER BY id` and deterministic
rows `(1, 'before-restart')` and `(2, 'backup-sentinel')`. Query the rows, perform a
reviewed database restart, and query them again through the Service. The server
must return a `26.8.` version, become ready, and retain both rows. Observe the
memory limit, OOM events, and Pod restart count across the test window. An intended
restart is expected; an OOM kill or unexplained restart fails acceptance.

Use the public reviewed manual backup and scratch restore commands. After backup,
insert `(3, 'after-backup')` into the source. Restore the backup into the isolated
destination reported by Nagare and verify it contains exactly rows 1 and 2, while
the source contains all three. Also wait for one scheduled backup from this fresh
database, verify its accepted receipt and object bytes, and restore that backup
through the supported scheduled-receipt path described in
`docs/user/managed-databases.md`. Check the scheduled restore against the rows
present when that backup ran. This proves the scheduling path and native archive
format together, beyond merely inspecting YAML. Do not claim success based only on
Job completion. Record restored rows and unchanged source data as evidence.

Stop at a guard refusal or unexpected result and repair it before accepting M2.
If no suitable disposable context is available, record M2 as pending; do not mark
first-use readiness complete. An actual application smoke check can reuse the
ClickHouse analytics example when its declared credential and connection bindings
are available, but no application deployment is required to invent extra scope.

### M3 — Deliver an accurate first-use handoff


Update `docs/user/managed-databases.md`, `docs/user/config-reference.md`, and the
ClickHouse example README to describe the 26.8 default and valid current commands.
Correct nearby outdated example create/delete instructions when necessary for the
26.8 walkthrough to run through reviewed inventory. State that existing explicit
version declarations retain their version; changing a default does not upgrade
accepted databases. Explain that this operator has no ClickHouse data migration.
Store concise validation evidence under `docs/audits/ep199-clickhouse-26.8/`, with
commands, tested revision, resolved image, observations, and cleanup result. Retain
applicable candidate gate results; rerun only if later changes invalidate them.
Review whether any durable discovery warrants an ADR amendment; the version bump
itself does not require a new architectural decision. M3 is accepted when the
handoff names the tested build, the required checks pass, and M2 has real evidence.

## Concrete Steps


Run repository commands from `/Users/shinzui/Keikaku/bokuno/nagare` in the development
shell. First inspect the current worktree and version occurrences; preserve edits
belonging to other work. Registry discovery precedes any dependency API assumptions.

```bash
git status --short
mori registry search clickhouse
rg -n '25\.8|clickhouse/clickhouse-server:25|defaultEngineVersion' cli cluster/examples docs/user
curl -fsSL https://hub.docker.com/v2/repositories/clickhouse/clickhouse-server/tags/26.8
```

After the M1 edits, run the suites serially, each using its own package project.
Both must finish successfully. Inspect the dry-run output for server and backup
images and compare the unchanged resource behavior described above.

```bash
cabal test --project-dir=cli/nagare-dsl nagare-dsl-test --test-show-details=direct
cabal test --project-dir=cli/nagarectl nagarectl-test --test-show-details=direct
cabal test --project-dir=cli/nagare-harness --test-show-details=direct
cabal run --project-dir=cli/nagarectl nagarectl -- db create clickhouse ep199-ch --size 1Gi --memory 2Gi --dry-run
```

Before native confirmation, commit only the intended implementation files, with a
Conventional Commit message and `ExecPlan: docs/plans/199-prepare-clickhouse-26-8-for-first-production-use.md`
trailer. On a clean candidate tree, run the required gate and verify it:

```bash
just gate
just gate-verify HEAD
```

For M2, the following is the reviewed CLI sequence to incorporate into the bounded
validation script. Set `NAGARE_CONTEXT` to the selected disposable context first;
assert the kube server and node as required by the native-run runbook. These review
directories must be new paths in the script's temporary working directory. Use the
candidate-built CLI, not an older installed release. The `ep199-ch` namespace and
database names are dedicated to this exercise.

```bash
nagarectl context current
nagarectl db create clickhouse ep199-ch --namespace ep199-ch --size 1Gi --memory 2Gi \
  --recovery-backup ep199-ch-backup --recovery-key-version v1 --save-plan ./create-review
nagarectl inventory apply ./create-review --yes
nagarectl db get ep199-ch --namespace ep199-ch
nagarectl db restart ep199-ch --namespace ep199-ch --save-plan ./restart-review
nagarectl inventory apply ./restart-review --yes
nagarectl db backup ep199-ch --namespace ep199-ch --backup-id ep199-manual --save-plan ./backup-review
nagarectl inventory apply ./backup-review --yes
nagarectl db restore ep199-ch ep199-manual --namespace ep199-ch --restore-id ep199-manual --save-plan ./restore-review
nagarectl inventory apply ./restore-review --yes
```

Insert the authenticated SQL seeding, observations, and source-only third row at
the M2 boundaries above; derive credentials and scratch destination from accepted
state rather than hard-coding them. The implementation must record the full
reproducible validation sequence, including scheduled backup selection, SQL
assertions, and managed cleanup, in the evidence directory. Consult
`docs/user/managed-databases.md` for scheduled receipt selection and
`docs/user/backups-and-disaster-recovery.md` for verification. Update this section
with the exact final script invocation once written. The expected observable
results are `SELECT version()` returning `26.8.*`, persisted rows 1 and 2 after
restart, manual scratch rows 1 and 2, and source rows 1, 2, and 3 after restore.

For documentation changes, run the repository's actual documentation validator
and check the final patch:

```bash
just user-documentation-validate
git diff --check
```

## Validation and Acceptance


M1 requires observable default selection through the public dry run, exact caller
version preservation, consistent server/backup/restore image selection, and passing
DSL, CLI, and harness tests. M2 requires an actual fresh 26.8 process with both
connection protocols, authenticated access, persistence through reviewed restart,
verified manual and scheduled recovery into isolated destinations, and no memory
failure under the example limit. Those fresh 26.8 producer/consumer roundtrips are
the required integration proof. Do not add a 25.8 migration test: there is no old
installation to migrate. M3 requires accurate maintained documentation, gate
records, evidence of M2, and a handoff that clearly distinguishes local engine proof
from any unperformed cloud or application validation.

## Idempotence and Recovery


Read-only registry queries, tests, and dry runs can be repeated. Use a fresh review
directory for each planned operation and resume an interrupted inventory operation
through supported status/recovery commands before issuing a replacement. Backups
and restores have stable IDs; do not overwrite a previous run's artifacts to hide
a partial failure. Retire and collect only validation-owned resources through the
managed inventory workflow, following `docs/runbooks/inventory-operations.md`;
a retained PVC is not proof of cleanup. Never delete a shared context or unrelated
namespace. Keep evidence and record any remaining validation resources if cleanup
cannot complete. Reverting source edits before first use needs no data rollback.
Once real 26.8 data exists, do not mount it into 25.8 as a rollback experiment.

## Interfaces and Dependencies


No Haskell API, inventory schema, backup receipt format, or cloud resource design
change is planned. `defaultEngineVersion :: Engine -> EngineVersion` changes its
ClickHouse result; `mkEngineVersion` and explicit configuration remain supported.
Server and client image construction must continue following the database's
selected version. External dependencies are the official ClickHouse 26.8 images,
the validation context's existing object store, and the existing Nagare create,
restart, backup, restore, and inventory operations. No parent MasterPlan or
Intention ID is assigned at creation. This plan has no prerequisite migration and
must finish before claiming readiness for the upcoming first ClickHouse use.
