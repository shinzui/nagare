---
id: 277
slug: make-the-vm-resize-path-and-store-status-work-on-inventory-contexts
title: "Make the VM resize path and store status work on inventory contexts"
kind: exec-plan
created_at: 2026-11-23T02:04:19Z
intention: "intention_01m832b746ecm9y5x6errgzq05"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-23T02:04:19Z
  reviews:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-25T13:48:42Z
      verdict: "changes-requested"
      note: "M1's status-report test cannot reach the executable module, and the existing version-2 'future head' test contradicts the fix; code claims otherwise match the tree"
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-25T14:01:28Z
      mode: "update"
      note: "Apply review findings: testable status report in the library, version-3 future-head test, land HEAD, M3 narrowed to README and log, takeover refusal in the runbook"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-25T14:31:47Z
      mode: "implement"
      note: "M1 status fix, M2 runbook and M3 summary/log implemented"
---

# Make the VM resize path and store status work on inventory contexts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

On 2026-11-23 the Labs intranet (`mori://tan/tan-ng-labs`, context `intranet`) was resized from
`n2-standard-4` to `n2-standard-8` on Nagare 0.27.0. Two Nagare defects cost most of the effort and
one refused apply. The operator's record is
`mori://tan/tan-ng-labs/plans/25-resize-the-labs-vm-to-n2-standard-8`.

1. `docs/user/resizing-the-vm.md` gives a procedure that does not work on a context that has
   resource-inventory history, which every current cloud context does. Its `nagarectl context use`
   step does not write the new machine type into the Pulumi stack. Its `just infra-up` step
   (`nagarectl infra apply`) refuses with "legacy infra apply cannot safely mutate it. Use a reviewed
   inventory command". The working path is two reviewed `nagarectl platform bootstrap plan/apply`
   stages, and the doc never mentions it. Its "Growing the data disk" section has the same defect:
   it uses `pulumi config set nagare:dataDiskSizeGb`.
2. `nagarectl inventory store status --json` reports `"state": "unsupported-schema"` for every head
   at schema version 2. Every store whose journal holds a convergence event (EP-231) is at version 2,
   Labs included. The report omits `activeTransaction` and `executorClaim`. So the documented "no
   transaction is open" check (`jq '{activeTransaction, executorClaim}'`) prints `null`/`null` even
   while another session holds a transaction. On Labs that happened at 22:19 UTC on 2026-11-22.
   It happened again in [plan 282](282-resume-inventory-transactions-in-the-configured-local-object-store.md),
   whose M2 first read a stopped transaction as settled and left the fix to this plan.

After this plan, an operator following `docs/user/resizing-the-vm.md` on an inventory context resizes
the VM with no refused command. `inventory store status --json` on a version-2 head reports the
binding, generation, active transaction and executor claim, the same as on a version-1 head.


## Progress

- [x] `inventory store status` decodes every head schema the store reader supports. The report is
  built by a pure library function. A unit test gives it a version-2 head with an active
  transaction and an executor claim, and the report names both. A version-3 head still reports
  `unsupported-schema`. The existing "future head" test uses version 3. `just gate-commit` is
  green. (2026-11-25, 44b6400e. `supportedHeadSchemaVersion` in `Manifest.hs`;
  `Nagare.Inventory.StoreStatus` holds `storeStatusReport`, `storeStatusLine` and `publicDataFence`.
  The test is "store status reports a version 2 head in full and only a version 3 head as
  unsupported" in `EventsSourceSpec.hs`. It fails with the old `schema > 1` condition (`expected:
  Nothing, but got: Just (String "unsupported-schema")`) and passes with the shared range.
  `just gate-commit` green in 161 s. Against the local context the command prints
  `{"state":null,"activeTransaction":null,"executorClaim":null,"generation":2}`, but that head is
  version 1, so only the unit test covers version 2.)
- [x] `docs/user/resizing-the-vm.md` gives the inventory-context procedure for both the machine type
  and the data-disk size: the context line, then the stage-1 and stage-2 bootstrap reviews with
  what each must contain, then the checks. The legacy `infra preview`/`infra-up` path stays as a
  short section for contexts without inventory history. The status banner and the downtime
  estimate carry the measured Labs numbers. (2026-11-25; `just docs-validate` OK.)
- [x] The summary that repeats the old path is corrected: the "Resizing the VM" entry in
  `docs/user/README.md` (lines 101 to 103). `docs/user/log.md` has an entry for DOC-30.
  (2026-11-25.)
- [ ] Landed: `just gate-fast` clean, then `just land HEAD`, with the full gate green on the landed
  commit. (2026-11-25: `just gate-fast` green on 4ac7aaaa; `just mutation-check 44b6400e 9d961dc3`
  selects 0 of 206 records. Landing follows this commit; the full gate result is pending.)


## Surprises & Discoveries

- `InventoryObjectOpsSpec.hs` is at its size allowance (1045 lines in
  `scripts/haskell-size-allowances.json`), so the architecture audit refused the new test there.
  It went into the "wire" group of `cli/nagarectl/test/EventsSourceSpec.hs`, next to the test
  that decodes heads at versions 1, 2 and 3. The "future head" test stayed where it was.
- `just mutation-check HEAD` without a base selects every record, not none: `selectRecords` in
  `cli/nagare-harness/src/Nagare/Harness/Mutation.hs` returns all records when no range is given.
  The run was stopped after 32 minutes, and Concrete Steps now passes the base (FRIC-27).


## Decision Log

- Decision: keep the two bootstrap stages and document them. Do not merge them into one stage in this
  plan.
  Rationale: stage 1 re-sets the stack's Pulumi config, and the stage-2 Pulumi preview is computed
  from that config, so stage 2 cannot be planned until stage 1 has converged. Making one review carry
  both stages changes the cloud-foundation executor, which is code that guards data, and Labs no
  longer needs the change. If resizes become routine, it is a separate improvement request.
  Date: 2026-11-23
- Decision: fix the status command by sharing the store reader's supported-version check, not by
  bumping `1` to `2` in the command.
  Rationale: the reader in `cli/nagare-core/src/Nagare/Inventory/Store/Manifest.hs` already accepts
  versions 1 and 2. Bumping a second literal would let the two drift apart again at version 3, which
  is exactly how the command went stale after EP-231.
  Date: 2026-11-23
- Decision: move the status report's construction out of the executable into a pure function in the
  `nagarectl` library, and test that function.
  Rationale: the `nagarectl-test` suite builds only from `cli/nagarectl/test` against the library.
  No spec can import `Nagare.Cli.Commands.Inventory.Store`, so the report as written has no test and
  cannot get one. The command keeps the store reads, the repeated-read check and the printing.
  Date: 2026-11-25
- Decision: delete `cli/nagarectl/app/Nagare/Cli/Inventory/PublicEvidence.hs` instead of keeping it
  as a re-export. Its only other user, `Nagare.Cli.Commands.Inventory.Status`, now imports
  `publicDataFence` from `Nagare.Inventory.StoreStatus`.
  Date: 2026-11-25
- Decision: leave `docs/user/upgrades.md` and `docs/user/resource-inventory.md` unchanged.
  Rationale: the `upgrades.md` paragraph describes a head newer than the CLI supports, which stays
  true. The `resource-inventory.md` description of `store status` already states the fixed
  behaviour. The 2026-11-23 Progress item listed both in error.
  Date: 2026-11-25


## Outcomes & Retrospective

`inventory store status` now reports the binding, generation, active transaction and executor
claim for every head the reader decodes (versions 1 and 2), and `unsupported-schema` only for a
newer head. The version range is defined once, so the two cannot drift apart at version 3. The
resize runbook (DOC-30) gives the inventory-context path for both the machine type and the data
disk: the context line, then two reviewed `platform bootstrap` stages. The legacy path stays for
contexts without history. Still open: the full gate on the landed commit, and Labs gets the status
fix at its next upgrade. Nothing moves to an ADR: ADR 14 and ADR 22 already state the
context-owns-the-shape and reviewed-inventory rules the runbook now follows. Friction: FRIC-27
(mutation-check without a base), resolved by correcting Concrete Steps; CLAUDE.md already gives
the `REV BASE` form.


## Context and Orientation

**Inventory context.** A context whose inventory store head records substantive history, as tested by
`InventoryStore.hasSubstantiveHistory`. Every Nagare-managed resource of such a context is declared in
a typed inventory and changed only through reviewed plans: a plan writes a review directory, and
`… apply DIR --yes` executes exactly that review. The "cloud foundation" is the inventory scope that
owns the Pulumi stack, including its config keys. `nagare:machineType`, `nagare:bootDiskType`,
`nagare:bootDiskSizeGb` and `nagare:dataDiskSizeGb` are projected from the context file's
`NAGARE_MACHINE_TYPE`, `NAGARE_BOOT_DISK_TYPE`, `NAGARE_BOOT_DISK_SIZE_GB` and
`NAGARE_DATA_DISK_SIZE_GB` by `seedKeysFor` in `cli/nagarectl/src/Nagare/Init.hs`. See
[ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) (the context owns the VM shape) and
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (the typed
inventory).

**The guard that refuses `infra apply`.** `guardLegacyMutationInventory` in
`cli/nagarectl/app/Nagare/Cli/Runtime/Guards.hs`. It is correct and stays.

**What `context use` does on such a context.** `ContextUse` in
`cli/nagarectl/app/Nagare/Cli/Commands/Context.hs` writes the global current-context pointer. When
`cloudFoundationPending` is true it prints `Cloud foundation awaits a reviewed platform bootstrap
plan.` and seeds nothing. Editing `NAGARE_MACHINE_TYPE` makes the foundation pending, because the
accepted declaration no longer matches the context.

**The working resize path, as run on Labs** (from the Labs repository root, in its direnv shell):

```bash
# 1. Edit the context: export NAGARE_MACHINE_TYPE='n2-standard-8'
# 2. Stage 1: re-set the stack config. The review must hold exactly one operation:
#    CloudFoundationExecutor UpdateResource platform:cloud-foundation/pulumi-stack/<context>,
#    whose summary includes `config set --stack <context> nagare:machineType n2-standard-8`.
nagarectl platform bootstrap plan --out "$R1"
jq '.operations | length' "$R1/review.json"
nagarectl platform bootstrap apply "$R1" --yes
# 3. Stage 2: one PulumiExecutor operation per cloud resource. Only the VM declares a mutation.
nagarectl platform bootstrap plan --out "$R2"
jq -r '.operations[] | (.operation.resources[0]) + "  " + (.summary | capture("; (?<n>[0-9]+) declared").n)' "$R2/review.json" | grep -v '  0$'
nagarectl platform bootstrap apply "$R2" --yes
```

```text
1
platform:cloud/nagare-instance-vm/nagare-intranet  1
```

`nagarectl infra preview --save-plan DIR` still works as a read-only cross-check: one `update` on
`gcp:compute/instance:Instance` and no replace. Only `infra apply` is refused. Measured on Labs: stage 2
took about 7 minutes, of which the GCE stop/start was about 30 seconds (01:37:22 → 01:37:51 UTC), and
the intranet was unavailable for about 5 minutes. `allowStoppingForUpdate: true` in
`infra/pulumi/src/components/NagareInstance.ts` is what makes the update a stop/start.

**The status defect.** `runInventoryStoreStatus` in
`cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Store.hs` reads the head's `version` with
`InventoryStore.inspectHeadSchema` (`cli/nagare-core/src/Nagare/Inventory/Store.hs`). It takes the
`unsupported-schema` branch whenever `schema > 1`. The `FromJSON HeadManifest` instance in
`cli/nagare-core/src/Nagare/Inventory/Store/Manifest.hs` accepts `version == 1 || version == 2`
(EP-231: version 2 marks a journal holding a convergence event). `readHead`, used by every other
command, therefore decodes the Labs head. No mutation record under
`cli/nagarectl/test/mutations/` touches these files.

**Why the report has no test today.** The command module is part of the `nagarectl` executable
(`hs-source-dirs: app` in `cli/nagarectl/nagarectl.cabal`). The `nagarectl-test` suite builds from
`cli/nagarectl/test` and depends on the library (`cli/nagarectl/src`), so no spec imports a
`Nagare.Cli.*` module. The report also calls `publicDataFence` from
`cli/nagarectl/app/Nagare/Cli/Inventory/PublicEvidence.hs`, another executable module.
`inventoryStoreToken` is already in the library (`cli/nagarectl/src/Nagare/Target/Kinds.hs`).

**The existing test that names version 2 as the future.** The test "future canonical inventory head
remains discoverable without decoding ownership" in `cli/nagarectl/test/InventoryObjectOpsSpec.hs`
(line 104) publishes `{"version":2}` and asserts that `readHead` refuses it. After EP-231 that head
is refused for its missing fields, not for its version, so the test passes for the wrong reason.

**Foreign-owner refusal at plan time.** Since 224a34ff (after the Labs resize on 0.27.0),
`platform bootstrap plan` refuses a plan that updates an object whose fields another writer manages,
unless `--take-over-fields` is given. The procedure is "Repair configuration drift" in
`docs/runbooks/inventory-operations.md`. The Labs resize did not meet this refusal.

The unrelated `unsupported-schema` in `cli/nagarectl/app/Nagare/Cli/Platform/Upgrade.hs` is about
upgrade transactions, not the head, and is out of scope.


## Plan of Work

**M1, the status fix.** In `Manifest.hs`, name the supported range once (for example
`supportedHeadSchemaVersions :: [Int]`, or a predicate), use it in `FromJSON HeadManifest`, and
export it through `Nagare.Inventory.Store`.

Add a library module, for example `cli/nagarectl/src/Nagare/Inventory/StoreStatus.hs`, listed in the
library's `exposed-modules`. It holds one pure function that builds the JSON report from the store
kind token, the store URL and the raw head bytes:

```haskell
storeStatusReport :: Text -> Text -> ByteString -> Either StoreError Aeson.Value
```

It calls `inspectHeadSchema`, returns the `unsupported-schema` report only for a version outside the
supported range, and otherwise decodes the same bytes and returns the full report. Move
`publicDataFence` into the library with it, and keep `PublicEvidence.hs` importing it if other
executable modules use it. `runInventoryStoreStatus` keeps the two reads of `head.json`, the
"changed during status" check and the printing, and calls the function. The text output reads its
fields from the same result.

Test the function in `InventoryObjectOpsSpec.hs`: the report for a version-2 head with a transaction
and a claim lists both, and a version-3 head is `unsupported-schema` with no `activeTransaction`
key. Build the version-2 head by encoding a `HeadManifest`, as the other tests in that spec do. In
the existing "future head" test, change `{"version":2}` to `{"version":3}`. Run `just gate-commit`.

**M2, the runbook.** Rewrite "Resize, step by step" in `docs/user/resizing-the-vm.md` around the path
in Context and Orientation:
- a preflight that confirms no transaction is open, using the fixed `store status`;
- a disk snapshot as the restore point;
- stage 1 and stage 2, stating what each review must contain and to stop on anything else;
- what to do when a plan is refused because another writer manages a field: stop, and follow
  "Repair configuration drift" in `docs/runbooks/inventory-operations.md`. Do not add
  `--take-over-fields` as a routine part of the resize;
- the post-resize checks: node capacity, `server status`, a database query, booted system equals
  current system.

Change rollback to the same two stages with the old value. Never use `pulumi config set` there,
because the next stage overwrites it. Apply the same treatment to "Growing the data disk": the context
line `NAGARE_DATA_DISK_SIZE_GB`, then the two stages. Keep the growfs steps as they are. Move the old
`infra preview`/`infra-up` path into a short "Contexts without inventory history" section, naming the
refusal text so a reader knows which path applies. Replace the 🟡 status banner and the estimated
downtime with the Labs measurements.

**M3, the summary and the log.** Rewrite the "Resizing the VM" entry in `docs/user/README.md` to
name the context line, the two reviewed bootstrap stages and the measured downtime. Add an
`Update` entry for DOC-30 to `docs/user/log.md` under the date of the change.


## Concrete Steps

From the repository root:

```bash
just gate-commit                 # after M1
just mutation-check HEAD 9d961dc3  # with the base; selects 0 of 206 records
just gate-fast && just land HEAD # after M2 and M3
```

Docs-only commits (M2, M3) carry the gated ancestor's record forward.


## Validation and Acceptance

- **M1:** the version-2 assertion fails when `storeStatusReport` keeps the old `schema > 1`
  condition, because a version-2 head yields `unsupported-schema`, and passes with the shared range.
  Against a local context whose store has converged a transaction, so its head
  is version 2:

  ```bash
  nagarectl --context local inventory store status --json | jq '{state, activeTransaction, executorClaim, generation}'
  ```

  ```text
  {"state": null, "activeTransaction": null, "executorClaim": null, "generation": <n>}
  ```

  That is, there is no `unsupported-schema` and the generation is a number.
- **M2/M3:** following the runbook on a disposable local or cloud context needs no command beyond the
  ones it lists. A reader who runs `just infra-up` on an inventory context finds the refusal text
  in the doc, along with the path to use instead.
- No native confirmation is required: the status change is a read-only CLI report, and the resize
  path itself is unchanged code that ran natively on Labs on 2026-11-23.


## Idempotence and Recovery

Everything here is a CLI read path and documentation, so it is safe to repeat. If M1's shared range
breaks a caller of `FromJSON HeadManifest`, the gate shows it. Revert the commit; nothing writes
stores differently.


## Interfaces and Dependencies

`Nagare.Inventory.Store` (nagare-core) gains one export naming the supported head schema versions.
Its consumers are `Nagare.Inventory.Store.Manifest` and the new status module. The `nagarectl`
library gains that module (`storeStatusReport`) and `publicDataFence`; the executable's
`cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Store.hs` calls it. No wire format changes, and
the JSON report keeps its current keys. Labs gets the
status fix when it next upgrades. Until then, its operators read
`gs://<state-bucket>/inventory/head.json` with `jq '{activeTransaction, executorClaim}'`, as its plan 25
records.
