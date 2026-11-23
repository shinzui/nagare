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

After this plan, an operator following `docs/user/resizing-the-vm.md` on an inventory context resizes
the VM with no refused command. `inventory store status --json` on a version-2 head reports the
binding, generation, active transaction and executor claim, the same as on a version-1 head.


## Progress

- [ ] `inventory store status` decodes every head schema the store reader supports. A unit test
  publishes a version-2 head with an active transaction and an executor claim, and the status
  report names both. A head above the supported range still reports `unsupported-schema`.
  `just gate-commit` is green.
- [ ] `docs/user/resizing-the-vm.md` gives the inventory-context procedure for both the machine type
  and the data-disk size: the context line, then the stage-1 and stage-2 bootstrap reviews with
  what each must contain, then the checks. The legacy `infra preview`/`infra-up` path stays as a
  short section for contexts without inventory history. The status banner and the downtime
  estimate carry the measured Labs numbers.
- [ ] The summaries that repeat the old path are corrected: `docs/user/README.md` (line 102),
  `docs/user/upgrades.md` (the `inventory store status` paragraph near line 92), and
  `docs/user/resource-inventory.md` (the `store status` description, so it matches the fixed
  behaviour).
- [ ] Landed: `just gate-fast` clean, then `just land`, with the full gate green on the landed
  commit.


## Surprises & Discoveries

(None yet.)


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


## Outcomes & Retrospective

(To be filled at completion.)


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
command, therefore decodes the Labs head. The existing `inspectHeadSchema` tests are in
`cli/nagarectl/test/InventoryObjectOpsSpec.hs`. No mutation record under
`cli/nagarectl/test/mutations/` touches these files.

The unrelated `unsupported-schema` in `cli/nagarectl/app/Nagare/Cli/Platform/Upgrade.hs` is about
upgrade transactions, not the head, and is out of scope.


## Plan of Work

**M1, the status fix.** In `Manifest.hs`, name the supported range once (for example
`supportedHeadSchemaVersions :: [Int]`, or a predicate), use it in `FromJSON HeadManifest`, and
export it through `Nagare.Inventory.Store`. In `runInventoryStoreStatus`, take the
`unsupported-schema` branch only for a version outside that range. Test both cases in
`InventoryObjectOpsSpec.hs` or the spec that already covers store-status output, whichever exists:
the report for a version-2 head with a transaction and a claim lists both, and a version-3 head is
still `unsupported-schema`. Run `just gate-commit`.

**M2, the runbook.** Rewrite "Resize, step by step" in `docs/user/resizing-the-vm.md` around the path
in Context and Orientation:
- a preflight that confirms no transaction is open, using the fixed `store status`;
- a disk snapshot as the restore point;
- stage 1 and stage 2, stating what each review must contain and to stop on anything else;
- the post-resize checks: node capacity, `server status`, a database query, booted system equals
  current system.

Change rollback to the same two stages with the old value. Never use `pulumi config set` there,
because the next stage overwrites it. Apply the same treatment to "Growing the data disk": the context
line `NAGARE_DATA_DISK_SIZE_GB`, then the two stages. Keep the growfs steps as they are. Move the old
`infra preview`/`infra-up` path into a short "Contexts without inventory history" section, naming the
refusal text so a reader knows which path applies. Replace the 🟡 status banner and the estimated
downtime with the Labs measurements.

**M3, the summaries.** Make the three docs named in Progress match.


## Concrete Steps

From the repository root:

```bash
just gate-commit                 # after M1
just mutation-check HEAD         # expected to select no records
just gate-fast && just land      # after M2 and M3
```

Docs-only commits (M2, M3) carry the gated ancestor's record forward.


## Validation and Acceptance

- **M1:** the new test fails before the change, because a version-2 head yields `unsupported-schema`,
  and passes after it. Against a local context whose store has converged a transaction, so its head
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
Its consumers are `Nagare.Inventory.Store.Manifest` and
`cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Store.hs`. No wire format changes. Labs gets the
status fix when it next upgrades. Until then, its operators read
`gs://<state-bucket>/inventory/head.json` with `jq '{activeTransaction, executorClaim}'`, as its plan 25
records.
